#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || exec sudo bash "$0" "$@"

ROOT=/etc/maya4-naive
XUI_DB=/etc/x-ui/x-ui.db
XUI_RUNTIME=/usr/local/x-ui/bin/config.json
BACKUPS=/var/lib/maya4-naive/backups

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

[[ -s "$ROOT/bundle.json" ]] || die 'Maya4 tunnel is not installed'
[[ -s "$XUI_DB" && -s "$XUI_RUNTIME" ]] || die '3X-UI database/runtime missing'
systemctl is-active --quiet x-ui.service || die 'x-ui inactive'
systemctl is-active --quiet maya4-naive-client.service || die 'Naive client inactive'
systemctl is-active --quiet maya4-xudp-router.service || die 'Maya4 router inactive'

/usr/local/sbin/maya4-health >/dev/null || die 'Maya4 tunnel must be healthy before attach'

tag=$(python3 - "$XUI_RUNTIME" <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); xs=[]
for i in c.get('inbounds',[]):
    try: p=int(i.get('port',0))
    except: continue
    if p==443 and i.get('tag') and str(i.get('listen','')) not in ('127.0.0.1','::1','localhost'):
        xs.append(i['tag'])
if len(xs)!=1:
    raise SystemExit(f'expected exactly one public :443 inbound, found {len(xs)}')
print(xs[0])
PY
)

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
    if not row: raise RuntimeError('xrayTemplateConfig missing')
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
    if api is None: raise RuntimeError('api -> api route missing')

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
sleep 4
systemctl is-active --quiet x-ui.service || rollback 1
ss -H -ltn 'sport = :443' 2>/dev/null | grep -q . || rollback 1

PUBLIC_TAG="$tag" python3 - "$XUI_RUNTIME" <<'PY'
import json,os,sys
tag=os.environ['PUBLIC_TAG']; c=json.load(open(sys.argv[1]))
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
print('RUNTIME ROUTING OK')
PY

/usr/local/sbin/maya4-health >/dev/null || rollback 1
trap - ERR INT TERM
log "SUCCESS: public x-ui inbound -> Maya4 Naive :7996"
log "Backup: $bk/x-ui.db"
