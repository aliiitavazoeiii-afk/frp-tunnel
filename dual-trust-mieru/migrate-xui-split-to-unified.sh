#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || exec sudo bash "$0" "$@"

XUI_DB=/etc/x-ui/x-ui.db
XUI_RUNTIME=/usr/local/x-ui/bin/config.json
POOL=/usr/local/sbin/lane3-pool
STATE=/var/lib/dual-trust-mieru/lane3
BACKUPS="$STATE/backups"

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

[[ -s "$XUI_DB" && -s "$XUI_RUNTIME" ]] || die 'x-ui DB/runtime missing'
[[ -x "$POOL" ]] || die 'unified pool controller missing'
[[ "$("$POOL" status)" == ENABLED ]] || die 'Naive is not enabled in unified :7990 pool'
systemctl is-active --quiet x-ui.service || die 'x-ui inactive'

curl -4 -sS --socks5-hostname 127.0.0.1:7990 --connect-timeout 5 --max-time 10   -o /dev/null https://www.gstatic.com/generate_204 || die 'unified :7990 path unhealthy'

tag=$(python3 - "$XUI_RUNTIME" <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); xs=[]
for i in c.get('inbounds',[]):
    try:p=int(i.get('port',0))
    except:continue
    if p==443 and i.get('tag') and str(i.get('listen','')) not in ('127.0.0.1','::1','localhost'):
        xs.append(i['tag'])
if len(xs)!=1:
    raise SystemExit(f'expected exactly one public :443 inbound, found {len(xs)}')
print(xs[0])
PY
)

mkdir -p "$BACKUPS"; chmod 0700 "$STATE" "$BACKUPS"
bk="$BACKUPS/xui-unified-$(date -u +%Y%m%dT%H%M%SZ)"
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

log 'Stopping x-ui for one controlled routing migration'
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
    if not any(o.get('tag')=='dual-tunnel' for o in obs):
        raise RuntimeError('dual-tunnel outbound missing')
    cfg['outbounds']=[o for o in obs if o.get('tag')!='lane3-naive']

    routing=cfg.setdefault('routing',{})
    rules=routing.setdefault('rules',[])
    api=None; rest=[]
    for r in rules:
        tags=r.get('inboundTag') or []
        if isinstance(tags,str): tags=[tags]
        if api is None and r.get('outboundTag')=='api' and 'api' in tags:
            api=r
            continue
        if str(r.get('ruleTag','')).startswith('lane3-managed-'):
            continue
        if r.get('outboundTag')=='lane3-naive':
            continue
        if r.get('outboundTag')=='dual-tunnel' and tag in tags:
            continue
        rest.append(r)
    if api is None:
        raise RuntimeError('api -> api route missing')

    unified={
      'type':'field',
      'inboundTag':[tag],
      'outboundTag':'dual-tunnel',
      'ruleTag':'triple-unified-entry'
    }
    routing['rules']=[api,unified]+rest
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
if any(o.get('tag')=='lane3-naive' for o in c.get('outbounds',[])):
    raise SystemExit('legacy lane3-naive outbound still present')
rules=c.get('routing',{}).get('rules',[])
if any(str(r.get('ruleTag','')).startswith('lane3-managed-') for r in rules):
    raise SystemExit('legacy lane3-managed rule still present')
hits=[]
for r in rules:
    tags=r.get('inboundTag') or []
    if isinstance(tags,str): tags=[tags]
    if tag in tags and r.get('outboundTag')=='dual-tunnel':
        hits.append(r)
if len(hits)!=1:
    raise SystemExit(f'expected one public -> dual-tunnel route, found {len(hits)}')
print('RUNTIME ROUTING OK')
PY

curl -4 -sS --socks5-hostname 127.0.0.1:7990 --connect-timeout 5 --max-time 10   -o /dev/null https://www.gstatic.com/generate_204 || rollback 1

printf '%s\n' unified-7990 > /etc/dual-trust-mieru/lane3/routing-mode
chmod 0600 /etc/dual-trust-mieru/lane3/routing-mode

if [[ -x /usr/local/sbin/lane3-xui-route ]]; then
  mv /usr/local/sbin/lane3-xui-route "/usr/local/sbin/lane3-xui-route.legacy-disabled-$(date -u +%Y%m%dT%H%M%SZ)"
fi

trap - ERR INT TERM
log "SUCCESS: all x-ui users now use dual-tunnel -> :7990 unified pool"
log "Legacy per-user Naive routing removed. Backup: $bk/x-ui.db"
