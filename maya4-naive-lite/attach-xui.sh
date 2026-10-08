#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || exec sudo bash "$0" "$@"

ROOT=/etc/maya4-naive
XUI_DB=/etc/x-ui/x-ui.db
BACKUPS=/var/lib/maya4-naive/backups

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

[[ -s "$ROOT/bundle.json" ]] || die 'Maya4 tunnel is not installed'
[[ -s "$XUI_DB" ]] || die '3X-UI database missing'
systemctl is-active --quiet x-ui.service || die 'x-ui inactive'
systemctl is-active --quiet maya4-naive-client.service || die 'Naive client inactive'
systemctl is-active --quiet maya4-xudp-router.service || die 'Maya4 router inactive'

/usr/local/sbin/maya4-health >/dev/null || die 'Maya4 tunnel must be healthy before attach'

# Modern 3X-UI stores user inbounds in SQLite and merges them into the generated
# Xray config at runtime. /usr/local/x-ui/bin/config.json is only the template,
# so discover the real public inbound from the DB, not from that file.
tag=$(python3 - "$XUI_DB" <<'PY'
import sqlite3,sys
p=sys.argv[1]
con=sqlite3.connect(p)
try:
    cols={r[1] for r in con.execute("PRAGMA table_info(inbounds)")}
    need={'tag','port','enable'}
    if not need.issubset(cols):
        raise SystemExit('3X-UI inbounds schema missing tag/port/enable')
    select=['tag','port','enable']
    if 'listen' in cols: select.append('listen')
    if 'protocol' in cols: select.append('protocol')
    if 'node_id' in cols: select.append('node_id')
    rows=con.execute(f"SELECT {','.join(select)} FROM inbounds").fetchall()
    names=select
    hits=[]
    for row in rows:
        d=dict(zip(names,row))
        if int(d.get('enable') or 0)!=1: continue
        if int(d.get('port') or 0)!=443: continue
        if 'node_id' in d and d['node_id'] is not None: continue
        listen=str(d.get('listen') or '').strip()
        if listen in ('127.0.0.1','::1','localhost'): continue
        hits.append(d)
    if len(hits)!=1:
        brief=[{k:x.get(k) for k in ('tag','port','listen','protocol')} for x in hits]
        raise SystemExit(f'expected exactly one enabled local public :443 inbound in x-ui DB, found {len(hits)}: {brief}')
    print(hits[0]['tag'])
finally:
    con.close()
PY
)

[[ -n "$tag" ]] || die 'could not resolve public :443 inbound tag'
log "Detected 3X-UI public inbound tag: $tag"

mkdir -p "$BACKUPS"; chmod 0700 /var/lib/maya4-naive "$BACKUPS"
bk="$BACKUPS/xui-attach-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$bk"; chmod 0700 "$bk"
cp -a "$XUI_DB" "$bk/x-ui.db"

rollback(){
  local rc=${1:-1}
  trap - ERR INT TERM
  log 'ROLLBACK: restoring previous x-ui database'
  systemctl stop x-ui.service >/dev/null 2>&1 || true
  cp -a "$bk/x-ui.db" "$XUI_DB"
  systemctl start x-ui.service >/dev/null 2>&1 || true
  sleep 3
  exit "$rc"
}
trap 'rollback $?' ERR
trap 'rollback 130' INT
trap 'rollback 143' TERM

systemctl stop x-ui.service

XUI_DB="$XUI_DB" PUBLIC_TAG="$tag" python3 <<'PY'
import json,os,sqlite3
p=os.environ['XUI_DB']; tag=os.environ['PUBLIC_TAG']
con=sqlite3.connect(p)
try:
    con.execute('BEGIN IMMEDIATE')
    row=con.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
    if not row:
        raise RuntimeError('xrayTemplateConfig missing')
    cfg=json.loads(row[0])

    obs=cfg.setdefault('outbounds',[])
    obs=[o for o in obs if o.get('tag')!='maya4-naive']
    obs.append({
      'tag':'maya4-naive',
      'protocol':'socks',
      'targetStrategy':'AsIs',
      'settings':{'servers':[{'address':'127.0.0.1','port':7996,'users':[]}]},
      'mux':{'enabled':False}
    })
    cfg['outbounds']=obs

    routing=cfg.setdefault('routing',{})
    rules=routing.setdefault('rules',[])
    api=None; rest=[]
    for r in rules:
        tags=r.get('inboundTag') or []
        if isinstance(tags,str): tags=[tags]
        if api is None and r.get('outboundTag')=='api' and 'api' in tags:
            api=r; continue
        if str(r.get('ruleTag',''))=='maya4-naive-all':
            continue
        rest.append(r)
    if api is None:
        raise RuntimeError('api -> api route missing')

    managed={
      'type':'field',
      'inboundTag':[tag],
      'outboundTag':'maya4-naive',
      'ruleTag':'maya4-naive-all'
    }
    routing['rules']=[api,managed]+rest
    payload=json.dumps(cfg,separators=(',',':'))
    con.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'",(payload,))
    con.commit()
finally:
    con.close()
PY

systemctl start x-ui.service
sleep 5
systemctl is-active --quiet x-ui.service || rollback 1
ss -H -ltn 'sport = :443' 2>/dev/null | grep -q . || rollback 1

# Validate the persisted template because modern 3X-UI generates real inbounds
# dynamically from SQLite; the on-disk config.json does not contain them.
XUI_DB="$XUI_DB" PUBLIC_TAG="$tag" python3 <<'PY'
import json,os,sqlite3
p=os.environ['XUI_DB']; tag=os.environ['PUBLIC_TAG']
con=sqlite3.connect(p)
try:
    row=con.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
    if not row: raise SystemExit('xrayTemplateConfig missing after attach')
    c=json.loads(row[0])
finally:
    con.close()

obs=[o for o in c.get('outbounds',[]) if o.get('tag')=='maya4-naive']
if len(obs)!=1:
    raise SystemExit('maya4-naive outbound missing/ambiguous')
sv=obs[0].get('settings',{}).get('servers') or []
if not sv or sv[0].get('address')!='127.0.0.1' or int(sv[0].get('port',0))!=7996:
    raise SystemExit('maya4-naive target wrong')

rules=c.get('routing',{}).get('rules',[])
hits=[r for r in rules if r.get('ruleTag')=='maya4-naive-all' and r.get('outboundTag')=='maya4-naive']
if len(hits)!=1:
    raise SystemExit('maya4 managed route missing')
tags=hits[0].get('inboundTag') or []
if isinstance(tags,str): tags=[tags]
if tag not in tags:
    raise SystemExit('maya4 route points to wrong inbound')
print('X-UI TEMPLATE ROUTING OK')
PY

/usr/local/sbin/maya4-health >/dev/null || rollback 1
trap - ERR INT TERM
log "SUCCESS: 3X-UI inbound $tag -> Maya4 Naive :7996"
log "Backup: $bk/x-ui.db"
