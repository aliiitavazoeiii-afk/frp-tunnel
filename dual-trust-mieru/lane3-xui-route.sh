#!/usr/bin/env bash
set -Eeuo pipefail
LIB=/usr/local/lib/dual-trust-mieru-lane3/lane3-common.sh
[[ -s "$LIB" ]] || LIB="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lane3-common.sh"
source "$LIB"
l3_root
l3_mkdirs

XUI_DB=/etc/x-ui/x-ui.db
XUI_RUNTIME=/usr/local/x-ui/bin/config.json
MODE_FILE="$L3_ROOT/routing-mode"
USERS_FILE="$L3_ROOT/assigned-users.txt"
mkdir -p "$L3_STATE/backups"
touch "$USERS_FILE"; chmod 0600 "$USERS_FILE"
[[ -s "$MODE_FILE" ]] || { echo all-legacy > "$MODE_FILE"; chmod 0600 "$MODE_FILE"; }

public_tag(){
  python3 - "$XUI_RUNTIME" <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); xs=[]
for i in c.get('inbounds',[]):
    try:p=int(i.get('port',0))
    except:continue
    if p==443 and i.get('tag') and str(i.get('listen','')) not in ('127.0.0.1','::1','localhost'):
        xs.append(i['tag'])
if len(xs)!=1: raise SystemExit(f'expected exactly one public :443 inbound, found {len(xs)}')
print(xs[0])
PY
}

apply_mode(){
  local mode=$1 tag bk
  [[ "$mode" == split || "$mode" == all-legacy || "$mode" == all-lane3 ]] || l3_die 'mode must be split|all-legacy|all-lane3'
  [[ -s "$XUI_DB" && -s "$XUI_RUNTIME" ]] || l3_die 'x-ui DB/runtime missing'
  systemctl is-active --quiet x-ui.service || l3_die 'x-ui inactive'
  if [[ "$mode" != all-legacy ]]; then
    systemctl is-active --quiet lane3-naive-client.service || l3_die 'Lane 3 Naive client inactive'
    systemctl is-active --quiet lane3-xudp-router.service || l3_die 'Lane 3 XUDP router inactive'
    l3_http "$L3_ENTRY_PORT" || l3_die 'Lane 3 path is not healthy; routing not changed'
  fi
  tag=$(public_tag)
  bk="$L3_STATE/backups/xui-route-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$bk"; chmod 0700 "$bk"
  cp -a "$XUI_DB" "$bk/x-ui.db"

  rollback(){
    local rc=${1:-1}
    trap - ERR INT TERM
    l3_log 'ROLLBACK: restoring previous x-ui database'
    systemctl stop x-ui.service >/dev/null 2>&1 || true
    cp -a "$bk/x-ui.db" "$XUI_DB"
    systemctl start x-ui.service >/dev/null 2>&1 || true
    sleep 3
    exit "$rc"
  }
  trap 'rollback $?' ERR; trap 'rollback 130' INT; trap 'rollback 143' TERM

  systemctl stop x-ui.service
  XUI_DB="$XUI_DB" L3_MODE="$mode" L3_TAG="$tag" L3_USERS="$USERS_FILE" L3_PREFIX="$L3_PREFIX" L3_PORT="$L3_ENTRY_PORT" python3 <<'PY'
import json,os,sqlite3
p=os.environ['XUI_DB']; mode=os.environ['L3_MODE']; tag=os.environ['L3_TAG']
users_file=os.environ['L3_USERS']; prefix=os.environ['L3_PREFIX']; port=int(os.environ['L3_PORT'])
explicit=[]
for raw in open(users_file,encoding='utf-8'):
    x=raw.strip()
    if x and not x.startswith('#') and x not in explicit: explicit.append(x)

con=sqlite3.connect(p)
try:
    con.execute('BEGIN IMMEDIATE')
    row=con.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
    if not row: raise RuntimeError('xrayTemplateConfig missing; current production attach must exist first')
    cfg=json.loads(row[0])
    obs=cfg.setdefault('outbounds',[])
    obs=[o for o in obs if o.get('tag')!='lane3-naive']
    obs.append({
      'tag':'lane3-naive','protocol':'socks','targetStrategy':'AsIs',
      'settings':{'servers':[{'address':'127.0.0.1','port':port,'users':[]}]},
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
        if str(r.get('ruleTag','')).startswith('lane3-managed-'): continue
        if r.get('outboundTag')=='lane3-naive': continue
        if r.get('outboundTag')=='dual-tunnel' and tag in tags: continue
        rest.append(r)
    if api is None: raise RuntimeError('api -> api route missing')
    if not any(o.get('tag')=='dual-tunnel' for o in obs):
        raise RuntimeError('existing dual-tunnel outbound missing')

    managed=[]
    if mode=='split':
        selectors=[f'regexp:^{prefix}']+explicit
        managed.append({'type':'field','inboundTag':[tag],'user':selectors,
                        'outboundTag':'lane3-naive','ruleTag':'lane3-managed-split'})
        managed.append({'type':'field','inboundTag':[tag],
                        'outboundTag':'dual-tunnel','ruleTag':'lane3-managed-default-legacy'})
    elif mode=='all-lane3':
        managed.append({'type':'field','inboundTag':[tag],
                        'outboundTag':'lane3-naive','ruleTag':'lane3-managed-all-lane3'})
    else:
        managed.append({'type':'field','inboundTag':[tag],
                        'outboundTag':'dual-tunnel','ruleTag':'lane3-managed-all-legacy'})
    routing['rules']=[api]+managed+rest
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

  L3_MODE="$mode" L3_TAG="$tag" python3 - "$XUI_RUNTIME" <<'PY'
import json,os,sys
mode=os.environ['L3_MODE']; tag=os.environ['L3_TAG']; c=json.load(open(sys.argv[1]))
obs=[o for o in c.get('outbounds',[]) if o.get('tag')=='lane3-naive']
if len(obs)!=1: raise SystemExit('runtime lane3-naive outbound missing/ambiguous')
sv=obs[0].get('settings',{}).get('servers') or []
if not sv or sv[0].get('address')!='127.0.0.1' or int(sv[0].get('port',0))!=7996:
    raise SystemExit('runtime Lane 3 target wrong')
rules=c.get('routing',{}).get('rules',[])
managed=[r for r in rules if str(r.get('ruleTag','')).startswith('lane3-managed-')]
if not managed: raise SystemExit('runtime Lane 3 managed route missing')
if mode=='split' and not any(r.get('outboundTag')=='lane3-naive' and r.get('user') for r in managed):
    raise SystemExit('runtime split user route missing')
if mode=='all-lane3' and not any(r.get('outboundTag')=='lane3-naive' and not r.get('user') for r in managed):
    raise SystemExit('runtime all-lane3 route missing')
if mode=='all-legacy' and not any(r.get('outboundTag')=='dual-tunnel' for r in managed):
    raise SystemExit('runtime all-legacy route missing')
print('RUNTIME OK')
PY

  printf '%s\n' "$mode" > "$MODE_FILE"; chmod 0600 "$MODE_FILE"
  trap - ERR INT TERM
  l3_log "SUCCESS: x-ui routing mode=$mode; backup=$bk/x-ui.db"
}

assign_user(){
  local email=$1 mode
  [[ -n "$email" ]] || l3_die 'email required'
  python3 - "$XUI_RUNTIME" "$email" <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); wanted=sys.argv[2]; found=False
for i in c.get('inbounds',[]):
    try:p=int(i.get('port',0))
    except:continue
    if p!=443: continue
    clients=i.get('settings',{}).get('clients') or []
    if any(str(x.get('email',''))==wanted for x in clients): found=True
if not found: raise SystemExit('user email not found on public :443 inbound')
PY
  grep -Fxq "$email" "$USERS_FILE" || printf '%s\n' "$email" >> "$USERS_FILE"
  sort -u "$USERS_FILE" -o "$USERS_FILE"; chmod 0600 "$USERS_FILE"
  mode=$(<"$MODE_FILE")
  [[ "$mode" == split ]] && apply_mode split || l3_log "Assigned $email to Lane 3 list; effective when mode=split"
}

unassign_user(){
  local email=$1 mode tmp
  [[ -n "$email" ]] || l3_die 'email required'
  tmp=$(mktemp)
  grep -Fxv "$email" "$USERS_FILE" > "$tmp" || true
  install -m 0600 "$tmp" "$USERS_FILE"; rm -f "$tmp"
  mode=$(<"$MODE_FILE")
  [[ "$mode" == split ]] && apply_mode split || l3_log "Removed $email from Lane 3 list"
}

list_users(){
  local mode; mode=$(<"$MODE_FILE")
  L3_MODE="$mode" L3_USERS="$USERS_FILE" L3_PREFIX="$L3_PREFIX" python3 - "$XUI_RUNTIME" <<'PY'
import json,os,sys
mode=os.environ['L3_MODE']; prefix=os.environ['L3_PREFIX']
assigned={x.strip() for x in open(os.environ['L3_USERS'],encoding='utf-8') if x.strip() and not x.startswith('#')}
c=json.load(open(sys.argv[1])); users=[]
for i in c.get('inbounds',[]):
    try:p=int(i.get('port',0))
    except:continue
    if p!=443: continue
    for x in i.get('settings',{}).get('clients') or []:
        e=str(x.get('email','')).strip()
        if e: users.append(e)
print(f'Routing mode: {mode}')
print(f'Auto Lane 3 prefix: {prefix}*')
print(f'{"EMAIL":40} ROUTE')
print('-'*54)
for e in sorted(set(users),key=str.lower):
    if mode=='all-lane3': route='LANE3'
    elif mode=='all-legacy': route='LEGACY'
    else: route='LANE3' if e.startswith(prefix) or e in assigned else 'LEGACY'
    print(f'{e[:40]:40} {route}')
PY
}

case "${1:-}" in
  apply) apply_mode "${2:-}" ;;
  assign) assign_user "${2:-}" ;;
  unassign) unassign_user "${2:-}" ;;
  list) list_users ;;
  *) echo "usage: $0 apply split|all-legacy|all-lane3 | assign EMAIL | unassign EMAIL | list" >&2; exit 2 ;;
esac
