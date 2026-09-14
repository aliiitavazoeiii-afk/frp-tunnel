#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-status}"
XUI_DB="/etc/x-ui/x-ui.db"
RUNTIME="/usr/local/x-ui/bin/config.json"
STATE_DIR="/var/lib/anytls-tunnel/backups"
BLOCK_TAG="anytls-quic-block"
ANYTLS_TAG="anytls-tunnel"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ "$MODE" == "on" || "$MODE" == "off" || "$MODE" == "status" ]] || die "usage: sudo bash quic-fallback-test.sh on|off|status"
[[ -f "$XUI_DB" ]] || die "x-ui DB missing: $XUI_DB"

runtime_status(){
  [[ -f "$RUNTIME" ]] || { echo "runtime config missing"; return 1; }
  python3 <<'PY'
import json
p='/usr/local/x-ui/bin/config.json'
c=json.load(open(p))
ins=[]
for i in c.get('inbounds',[]):
    try: port=int(i.get('port',0))
    except Exception: continue
    if port==443 and str(i.get('listen','')) not in ('127.0.0.1','::1','localhost'):
        ins.append(i.get('tag'))
block=[o for o in c.get('outbounds',[]) if o.get('tag')=='anytls-quic-block']
rules=[]
for r in c.get('routing',{}).get('rules',[]):
    if r.get('outboundTag')=='anytls-quic-block': rules.append(r)
print('public_443_inbounds=',ins)
print('quic_block_outbound=', 'present' if block else 'absent')
print('quic_block_rules=', rules)
PY
}

if [[ "$MODE" == "status" ]]; then
  runtime_status
  exit 0
fi

systemctl is-active --quiet x-ui || die "x-ui is not active"
[[ -f "$RUNTIME" ]] || die "x-ui runtime missing: $RUNTIME"

INBOUND_TAG=$(python3 <<'PY'
import json
c=json.load(open('/usr/local/x-ui/bin/config.json'))
xs=[]
for i in c.get('inbounds',[]):
    try: port=int(i.get('port',0))
    except Exception: continue
    if port!=443: continue
    if str(i.get('listen','')) in ('127.0.0.1','::1','localhost'): continue
    if i.get('tag'): xs.append(i['tag'])
if len(xs)!=1:
    raise SystemExit('ERROR: expected exactly one public inbound on 443, found %r' % xs)
print(xs[0])
PY
) || die "could not uniquely detect public 443 inbound"

mkdir -p "$STATE_DIR"
BACKUP_DIR="$STATE_DIR/quic-fallback-$(date -u +%Y%m%dT%H%M%SZ)"
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

systemctl stop x-ui
MODE="$MODE" XUI_DB="$XUI_DB" INBOUND_TAG="$INBOUND_TAG" python3 <<'PY'
import json, os, sqlite3
p=os.environ['XUI_DB']; mode=os.environ['MODE']; inbound=os.environ['INBOUND_TAG']
block='anytls-quic-block'
con=sqlite3.connect(p)
try:
    con.execute('BEGIN IMMEDIATE')
    row=con.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
    if not row: raise RuntimeError('xrayTemplateConfig not found')
    cfg=json.loads(row[0])
    obs=cfg.setdefault('outbounds',[])
    routing=cfg.setdefault('routing',{})
    rules=routing.setdefault('rules',[])

    # Remove only rules created by this test.
    rules[:] = [r for r in rules if not (r.get('outboundTag')==block and r.get('network')=='udp' and str(r.get('port'))=='443')]

    if mode=='on':
        matches=[o for o in obs if o.get('tag')==block]
        if len(matches)>1: raise RuntimeError('multiple quic block outbounds found')
        desired={'tag':block,'protocol':'blackhole','settings':{}}
        if matches:
            matches[0].clear(); matches[0].update(desired)
        else:
            obs.append(desired)
        # Put this before the general inbound -> anytls route.
        rule={'type':'field','inboundTag':[inbound],'network':'udp','port':'443','outboundTag':block}
        insert_at=0
        for idx,r in enumerate(rules):
            if r.get('outboundTag')=='anytls-tunnel' and inbound in (r.get('inboundTag') or []):
                insert_at=idx; break
        rules.insert(insert_at,rule)
    else:
        # Remove the dedicated blackhole outbound only if nothing else references it.
        if not any(r.get('outboundTag')==block for r in rules):
            obs[:] = [o for o in obs if o.get('tag')!=block]

    con.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'",(json.dumps(cfg,separators=(',',':')),))
    con.commit()
finally:
    con.close()
PY

systemctl start x-ui
sleep 4
systemctl is-active --quiet x-ui || die "x-ui failed after QUIC fallback change"
ss -H -ltn 'sport = :443' | grep -q . || die "public TCP/443 missing after x-ui restart"

MODE="$MODE" INBOUND_TAG="$INBOUND_TAG" python3 <<'PY'
import json,os
c=json.load(open('/usr/local/x-ui/bin/config.json'))
mode=os.environ['MODE']; inbound=os.environ['INBOUND_TAG']; block='anytls-quic-block'
rules=c.get('routing',{}).get('rules',[])
match=[r for r in rules if r.get('outboundTag')==block and r.get('network')=='udp' and str(r.get('port'))=='443' and inbound in (r.get('inboundTag') or [])]
if mode=='on' and len(match)!=1: raise SystemExit(f'expected one QUIC block rule, found {len(match)}')
if mode=='off' and match: raise SystemExit('QUIC block rule still present after disable')
obs=[o for o in c.get('outbounds',[]) if o.get('tag')=='anytls-tunnel']
if len(obs)!=1: raise SystemExit('anytls-tunnel outbound missing or duplicated')
o=obs[0]
if o.get('targetStrategy')!='ForceIPv4': raise SystemExit('anytls-tunnel lost ForceIPv4')
st=o.get('settings',{}); servers=st.get('servers') or []
if not servers or int(servers[0].get('port',0))!=7891: raise SystemExit('anytls-tunnel no longer points to 7891')
print('RUNTIME OK: QUIC fallback', 'ENABLED' if mode=='on' else 'DISABLED')
print('AnyTLS path preserved: 127.0.0.1:7891 ForceIPv4')
PY

trap - EXIT
if [[ "$MODE" == "on" ]]; then
  log "SUCCESS: UDP/443 is blocked only for the public VPN inbound; apps should fall back to TCP/HTTP2"
  log "Test YouTube/Instagram after fully reconnecting the client. Roll back with: sudo bash quic-fallback-test.sh off"
else
  log "SUCCESS: QUIC fallback test disabled; UDP/443 flows to AnyTLS/XUDP again"
fi
