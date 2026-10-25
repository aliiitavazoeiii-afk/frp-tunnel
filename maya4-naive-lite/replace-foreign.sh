#!/usr/bin/env bash
# Maya4 Naive Lite foreign swap: full-path candidate tests, then targeted cutover
# and rollback. Does NOT reinstall/modify/restart x-ui or any other Maya server.
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "$0")" && pwd)
source "$B/common.sh"
root_only
umask 077
[[ $# -eq 1 && -s "$1" ]] || die "Usage: sudo bash $0 /root/new-maya4-naive-client.json"
BUNDLE=$1
D=/etc/maya4-naive
S=/var/lib/maya4-naive
LIB=/usr/local/lib/maya4-naive
[[ -s "$D/naive.json" && -s "$D/xudp-router.json" && -s "$D/bundle.json" ]] ||
  die "live Maya4 files missing (do NOT rerun install-iran.sh)"
[[ -x "$LIB/naive" && -x "$LIB/xray" ]] || die "Maya4 binaries missing"
for unit in x-ui maya4-naive-client maya4-xudp-router; do
  systemctl is-active --quiet "$unit.service" || die "inactive service: $unit"
done
XUI_VER=$(/usr/local/x-ui/x-ui -v 2>/dev/null | tr -d '[:space:]' | sed 's/^v//')
[[ "$XUI_VER" == '2.9.4' ]] || die "requires current x-ui v2.9.4 (not $XUI_VER)"
jq -e '
.version==1 and .kind=="maya4-naive" and .port==443 and
(.public_ip|type=="string" and test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$")) and
(.domain|type=="string" and test("^[a-zA-Z0-9.-]+\\.[A-Za-z]{2,}$")) and
(.username|type=="string" and test("^[A-Za-z0-9_-]{2,60}$")) and
(.password|type=="string" and test("^[A-Za-z0-9]{32,128}$")) and
(.xudp_uuid|type=="string" and test("^[0-9a-fA-F-]{36}$"))
' "$BUNDLE" >/dev/null || die "new foreign bundle invalid"
IP=$(jq -r '.public_ip' "$BUNDLE")
DOMAIN=$(jq -r '.domain' "$BUNDLE")
valid_ipv4 "$IP" || die "invalid IPv4"
OLDIP=$(jq -r '.public_ip // ""' "$D/bundle.json")
[[ "$IP" != "$OLDIP" ]] || die "candidate IP is the current IP"
getent ahostsv4 "$DOMAIN" | awk '{print $1}' | grep -Fxq "$IP" ||
  die "new DNS domain must resolve to new foreign IP"
for port in 17995 17996; do
  ! ss -H -ltn "sport = :$port" 2>/dev/null | grep -q . ||
    die "temporary test port occupied: $port"
done
mkdir -p "$S/backups"
chmod 0700 "$S" "$S/backups"
TMP=$(mktemp -d "$S/.foreign-replace.XXXXXXXX")
chmod 0700 "$TMP"
NPID='' XPID='' CUTOVER=0 SUCCESS=0 BK=''
stop_trials(){
  for pid in "$XPID" "$NPID"; do
    if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  done
  XPID='' NPID=''
}
finish(){
  rc=$?
  trap - EXIT INT TERM
  stop_trials
  if (( rc != 0 && CUTOVER == 1 )); then
    log 'ROLLBACK: restoring old foreign; x-ui is untouched'
    cp -a "$BK/naive.json" "$D/naive.json" || true
    cp -a "$BK/xudp-router.json" "$D/xudp-router.json" || true
    cp -a "$BK/bundle.json" "$D/bundle.json" || true
    systemctl restart maya4-naive-client.service >/dev/null 2>&1 || true
    systemctl restart maya4-xudp-router.service >/dev/null 2>&1 || true
  fi
  if [[ -d "$TMP" ]]; then rm -rf -- "$TMP"; fi
  if (( rc != 0 )); then
    log 'FAILED: current foreign was not deliberately removed'
  elif (( SUCCESS == 1 )); then
    log "SUCCESS: Maya4 foreign replaced. Old config backup: $BK"
  fi
  exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log "Building isolated trial for $DOMAIN ($IP); live routes unchanged"
python3 - "$BUNDLE" "$TMP" <<'PY'
import json, os, sys
from pathlib import Path
b=json.load(open(sys.argv[1]))
root=Path(sys.argv[2])
def dump(name,obj):
 p=root/name
 with p.open('w') as f: json.dump(obj,f,indent=2)
 os.chmod(p,0o600)
def naive(port):
 return {
   'listen':f'socks://127.0.0.1:{port}',
   'proxy':f"https://{b['username']}:{b['password']}@{b['domain']}",
   'host-resolver-rules':f"MAP {b['domain']} {b['public_ip']}"
 }
def xray(entry,carrier):
 return {
   'log':{'loglevel':'warning'},
   'inbounds':[{'tag':'maya4-in','listen':'127.0.0.1','port':entry,
               'protocol':'socks','settings':{'auth':'noauth','udp':True}}],
   'outbounds':[
     {'tag':'xudp-maya4','protocol':'vless',
      'settings':{'address':'xudp-maya4.internal','port':2443,
                  'id':b['xudp_uuid'],'encryption':'none'},
      'streamSettings':{'network':'raw','sockopt':{'dialerProxy':'carrier-maya4'}},
      'mux':{'enabled':True,'concurrency':-1,'xudpConcurrency':8,'xudpProxyUDP443':'allow'}},
     {'tag':'carrier-maya4','protocol':'socks',
      'settings':{'address':'127.0.0.1','port':carrier}}
   ],
   'routing':{'domainStrategy':'AsIs','rules':[
      {'type':'field','inboundTag':['maya4-in'],'network':'tcp','outboundTag':'carrier-maya4'},
      {'type':'field','inboundTag':['maya4-in'],'network':'udp','outboundTag':'xudp-maya4'}]}
 }
dump('trial-naive.json',naive(17995))
dump('trial-router.json',xray(17996,17995))
dump('live-naive.json',naive(7995))
dump('live-router.json',xray(7996,7995))
PY
"$LIB/xray" run -test -c "$TMP/trial-router.json" >/dev/null
"$LIB/xray" run -test -c "$TMP/live-router.json" >/dev/null
"$LIB/naive" "$TMP/trial-naive.json" >"$TMP/naive.log" 2>&1 &
NPID=$!
"$LIB/xray" run -c "$TMP/trial-router.json" >"$TMP/router.log" 2>&1 &
XPID=$!
for port in 17995 17996; do
  ready=0
  for i in $(seq 1 12); do
    if ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .; then ready=1; break; fi
    sleep 1
  done
  (( ready == 1 )) || die "isolated test listener did not start: $port"
done
http_test(){
  p=$1
  label=$2
  good=0
  for i in 1 2 3 4 5; do
    code=$(curl -4 -sS --socks5-hostname "127.0.0.1:$p" \
      --connect-timeout 5 --max-time 12 -o /dev/null -w '%{http_code}' \
      https://www.gstatic.com/generate_204 2>/dev/null || true)
    if [[ "$code" == 204 ]]; then good=$((good+1)); fi
    (( good >= 3 )) && { log "$label: TCP OK 3/5"; return 0; }
    sleep 1
  done
  log "$label: TCP FAIL ($good/5)"
  return 1
}
udp_test(){
  p=$1
  good=0
  for i in 1 2 3; do udp_probe "$p" && good=$((good+1)) || true; done
  log "UDP/XUDP $p: $good/3"
  (( good >= 2 ))
}
http_test 17995 'candidate direct' || die "new foreign direct TCP failed, no cutover"
http_test 17996 'candidate full' || die "new foreign full TCP failed, no cutover"
udp_test 17996 || die "new foreign UDP/XUDP failed, no cutover"
log 'Candidate PASSED independent TCP + XUDP tests; preparing live cutover'
stop_trials

# All live state is backed up before ANY operational change.
BK="$S/backups/foreign-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$BK"; chmod 0700 "$BK"
cp -a "$D/naive.json" "$BK/naive.json"
cp -a "$D/xudp-router.json" "$BK/xudp-router.json"
cp -a "$D/bundle.json" "$BK/bundle.json"
systemctl is-active --quiet x-ui.service || die "x-ui not active; abort"
CUTOVER=1
install -m 0600 "$TMP/live-naive.json" "$D/naive.json"
install -m 0600 "$TMP/live-router.json" "$D/xudp-router.json"
install -m 0600 "$BUNDLE" "$D/bundle.json"
log 'CUTOVER: restarting only Maya4 Naive client and XUDP router (not x-ui)'
systemctl restart maya4-naive-client.service
systemctl restart maya4-xudp-router.service
sleep 3
systemctl is-active --quiet x-ui.service || die "x-ui became inactive"
systemctl is-active --quiet maya4-naive-client.service || die "Naive service inactive"
systemctl is-active --quiet maya4-xudp-router.service || die "XUDP service inactive"
http_test 7995 'LIVE direct' || die "live direct path failed"
http_test 7996 'LIVE full' || die "live full TCP path failed"
udp_test 7996 || die "live UDP path failed"
CUTOVER=0
SUCCESS=1
log 'New foreign active. Existing x-ui and public :443 were preserved.'
log 'Old foreign VPS has NOT been deleted; retire only after confirming real users.'
