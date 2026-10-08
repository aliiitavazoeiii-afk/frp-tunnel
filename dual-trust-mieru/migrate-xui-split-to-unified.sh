#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || exec sudo bash "$0" "$@"

XUI_DB=/etc/x-ui/x-ui.db
XUI_RUNTIME=/usr/local/x-ui/bin/config.json
DISPATCHER=/etc/dual-trust-mieru/iran/dispatcher.yaml
POOL=/usr/local/sbin/lane3-pool
HEALTH=/usr/local/sbin/dual-health
STATE=/var/lib/dual-trust-mieru/lane3
BACKUPS="$STATE/backups"
LOCK=/run/dual-trust-mieru-unified-migration.lock
MODE_FILE=/etc/dual-trust-mieru/lane3/routing-mode

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

exec 9>"$LOCK"
flock -n 9 || die 'another unified migration is already running'

[[ -s "$XUI_DB" && -s "$XUI_RUNTIME" ]] || die 'x-ui DB/runtime missing'
[[ -s "$DISPATCHER" ]] || die 'dispatcher config missing'
[[ -x "$POOL" ]] || die 'unified pool controller missing'
[[ -x "$HEALTH" ]] || die 'unified health tool missing'
systemctl is-active --quiet x-ui.service || die 'x-ui inactive'
systemctl is-active --quiet dual-dispatcher.service || die 'dispatcher inactive'
systemctl is-active --quiet lane3-naive-client.service || die 'Naive client inactive'
systemctl is-active --quiet lane3-xudp-router.service || die 'Naive XUDP router inactive'

# Naive must be healthy while still outside the unified pool. This proves the
# carrier is good before user traffic is moved.
"$HEALTH" --full naive || die 'Naive preflight health failed; migration not started'

curl -4 -sS --socks5-hostname 127.0.0.1:7990 --connect-timeout 5 --max-time 10 \
  -o /dev/null https://www.gstatic.com/generate_204 || die 'current :7990 path unhealthy'

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

pool_before=$("$POOL" status)
[[ "$pool_before" == ENABLED || "$pool_before" == DISABLED ]] || die "unexpected pool status: $pool_before"
mode_before='missing'
[[ -s "$MODE_FILE" ]] && mode_before=$(<"$MODE_FILE")

mkdir -p "$BACKUPS"; chmod 0700 "$STATE" "$BACKUPS"
bk="$BACKUPS/atomic-unified-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$bk"; chmod 0700 "$bk"
cp -a "$XUI_DB" "$bk/x-ui.db"
cp -a "$DISPATCHER" "$bk/dispatcher.yaml"
printf '%s\n' "$pool_before" > "$bk/pool-before"
printf '%s\n' "$mode_before" > "$bk/routing-mode-before"
chmod 0600 "$bk/"*

rollback(){
  local rc=${1:-1}
  trap - ERR INT TERM
  log 'ROLLBACK: restoring previous x-ui database and dispatcher'
  systemctl stop x-ui.service >/dev/null 2>&1 || true
  cp -a "$bk/x-ui.db" "$XUI_DB"
  cp -a "$bk/dispatcher.yaml" "$DISPATCHER"
  chmod 0600 "$XUI_DB" "$DISPATCHER"
  systemctl restart dual-dispatcher.service >/dev/null 2>&1 || true
  systemctl start x-ui.service >/dev/null 2>&1 || true
  if [[ "$mode_before" == missing ]]; then
    rm -f "$MODE_FILE"
  else
    printf '%s\n' "$mode_before" > "$MODE_FILE"
    chmod 0600 "$MODE_FILE"
  fi
  sleep 4
  log "ROLLBACK complete. Backup retained: $bk"
  exit "$rc"
}
trap 'rollback $?' ERR
trap 'rollback 130' INT
trap 'rollback 143' TERM

# Stop user ingress first. This removes the temporary double-loading condition
# where split users hit Naive directly while :7990 also selects Naive.
log 'Stopping x-ui for atomic split -> unified migration'
systemctl stop x-ui.service

# While no public users can create new sessions, add Naive to the same
# sticky-sessions load-balancer used by Trust and Mieru.
if [[ "$pool_before" != ENABLED ]]; then
  log 'Enabling Naive in unified :7990 pool while x-ui is stopped'
  "$POOL" enable
fi
[[ "$("$POOL" status)" == ENABLED ]] || rollback 1

# Convert x-ui back to exactly one public routing decision:
# public :443 -> dual-tunnel -> 127.0.0.1:7990.
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
        if str(r.get('ruleTag',''))=='triple-unified-entry':
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

log 'Starting x-ui on unified :7990 routing'
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
if hits[0].get('ruleTag')!='triple-unified-entry':
    raise SystemExit('public route is not triple-unified-entry')
print('RUNTIME ROUTING OK')
PY

# Let real users reconnect, then verify Naive specifically under its actual
# three-way load. Retry once to avoid rolling back on one transient probe.
log 'Waiting for real user reconnects before post-migration health'
sleep 8
naive_ok=0
for attempt in 1 2; do
  if "$HEALTH" --quick naive; then
    naive_ok=1
    break
  fi
  log "Naive post-load health attempt $attempt/2 failed"
  sleep 4
done
(( naive_ok == 1 )) || rollback 1

unified_ok=0
for attempt in 1 2 3; do
  if curl -4 -sS --socks5-hostname 127.0.0.1:7990 --connect-timeout 5 --max-time 10 \
      -o /dev/null https://www.gstatic.com/generate_204; then
    unified_ok=1
    break
  fi
  sleep 2
done
(( unified_ok == 1 )) || rollback 1

printf '%s\n' unified-7990 > "$MODE_FILE"
chmod 0600 "$MODE_FILE"

if [[ -x /usr/local/sbin/lane3-xui-route ]]; then
  mv /usr/local/sbin/lane3-xui-route \
    "/usr/local/sbin/lane3-xui-route.legacy-disabled-$(date -u +%Y%m%dT%H%M%SZ)"
fi

trap - ERR INT TERM
log 'SUCCESS: atomic migration complete'
log 'All x-ui users now use dual-tunnel -> :7990 -> Trust/Mieru/Naive'
log "Legacy per-user Naive routing removed. Backup: $bk"
