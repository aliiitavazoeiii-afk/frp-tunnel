#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
D=/etc/dual-trust-mieru/iran
BIN=/usr/local/lib/dual-trust-mieru
STATE=/var/lib/dual-trust-mieru

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'ERROR: run as root' >&2; exit 1; }
[[ -s "$D/xudp.json" && -s "$D/mieru-carrier.yaml" ]] || { echo 'ERROR: dual Iran runtime missing' >&2; exit 1; }
[[ -x "$BIN/xray" && -x "$BIN/mihomo" ]] || { echo 'ERROR: dual binaries missing' >&2; exit 1; }

for s in dual-trust-client dual-mieru-carrier dual-xudp-bridge dual-dispatcher; do
  systemctl is-active --quiet "$s.service" || { echo "ERROR: $s is not active" >&2; exit 1; }
done

TS=$(date -u +%Y%m%dT%H%M%SZ)
BK="$STATE/backups/live-final-$TS"
mkdir -p "$BK"
chmod 0700 "$BK"
cp -a "$D/xudp.json" "$BK/xudp.json"
cp -a "$D/mieru-carrier.yaml" "$BK/mieru-carrier.yaml"

rollback(){
  rc=$?
  trap - ERR INT TERM
  echo "ROLLBACK: restoring $BK" >&2
  cp -a "$BK/xudp.json" "$D/xudp.json"
  cp -a "$BK/mieru-carrier.yaml" "$D/mieru-carrier.yaml"
  systemctl restart dual-mieru-carrier.service >/dev/null 2>&1 || true
  systemctl restart dual-xudp-bridge.service >/dev/null 2>&1 || true
  sleep 2
  echo 'ROLLBACK complete; dispatcher/x-ui config was never modified.' >&2
  exit "$rc"
}
trap rollback ERR INT TERM

TMP_X=$(mktemp "$D/.xudp.live-final.XXXXXX.json")
TMP_M=$(mktemp "$D/.mieru.live-final.XXXXXX.yaml")
cleanup(){ rm -f "$TMP_X" "$TMP_M"; }
trap cleanup EXIT

python3 - "$D/xudp.json" "$TMP_X" <<'PY'
import json,sys
src,dst=sys.argv[1],sys.argv[2]
with open(src) as f: c=json.load(f)

for ob in c.get('outbounds',[]):
    if ob.get('tag')=='xudp-trust':
        ob.setdefault('settings',{})['address']='xudp-trust.internal'

c['routing']={
  'domainStrategy':'AsIs',
  'rules':[
    {'type':'field','inboundTag':['trust-in'],'network':'tcp','outboundTag':'carrier-trust'},
    {'type':'field','inboundTag':['trust-in'],'network':'udp','outboundTag':'xudp-trust'},
    {'type':'field','inboundTag':['mieru-in'],'network':'tcp','outboundTag':'carrier-mieru'},
    {'type':'field','inboundTag':['mieru-in'],'network':'udp','outboundTag':'xudp-mieru'},
  ]
}
with open(dst,'w') as f: json.dump(c,f,indent=2)
PY
chmod 0600 "$TMP_X"

python3 - "$D/mieru-carrier.yaml" "$TMP_M" <<'PY'
import sys
src,dst=sys.argv[1],sys.argv[2]
s=open(src).read()
if 'multiplexing: MULTIPLEXING_LOW' in s:
    s=s.replace('multiplexing: MULTIPLEXING_LOW','multiplexing: MULTIPLEXING_OFF')
elif 'multiplexing: MULTIPLEXING_OFF' not in s:
    raise SystemExit('ERROR: unknown/missing Mieru multiplexing mode')
open(dst,'w').write(s)
PY
chmod 0600 "$TMP_M"

grep -qE '^[[:space:]]*127\.0\.0\.1[[:space:]]+xudp-trust\.internal([[:space:]]|$)' /etc/hosts || \
  echo '127.0.0.1 xudp-trust.internal # dual-trust-mieru trust-xudp-hostname' >> /etc/hosts

"$BIN/xray" run -test -c "$TMP_X" >/dev/null
"$BIN/mihomo" -t -d "$D/mieru-data" -f "$TMP_M" >/dev/null

mv "$TMP_X" "$D/xudp.json"
TMP_X=''
mv "$TMP_M" "$D/mieru-carrier.yaml"
TMP_M=''
chmod 0600 "$D/xudp.json" "$D/mieru-carrier.yaml"

# Only Mieru carrier needs a carrier restart for MULTIPLEXING_OFF.
# The shared split router is restarted once to load the TCP/UDP routing rules.
systemctl restart dual-mieru-carrier.service
sleep 2
systemctl is-active --quiet dual-mieru-carrier.service
ss -H -ltn 'sport = :7994' | grep -q .

systemctl restart dual-xudp-bridge.service
sleep 2
systemctl is-active --quiet dual-xudp-bridge.service
ss -H -ltn 'sport = :7991' | grep -q .
ss -H -ltn 'sport = :7992' | grep -q .

strict(){
  local label=$1 port=$2 count=$3 ok=0 code
  echo "=== $label :$port ==="
  for i in $(seq 1 "$count"); do
    code=$(curl -4 -sS --socks5-hostname "127.0.0.1:$port" --connect-timeout 5 --max-time 8 \
      -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null || true)
    if [[ "$code" == 204 ]]; then ok=$((ok+1)); printf '%02d PASS\n' "$i"; else printf '%02d FAIL HTTP=%s\n' "$i" "${code:-000}"; fi
    sleep 0.10
  done
  echo "$label=$ok/$count"
  (( ok == count ))
}

strict TRUST-DIRECT 7993 10
strict MIERU-DIRECT 7994 10
strict TRUST-SPLIT-TCP 7991 20
strict MIERU-SPLIT-TCP 7992 20

install -m 0755 "$B/dual-probe-final.sh" /usr/local/sbin/dual-tunnel-probe
bash "$B/install-autoheal.sh"

/usr/local/sbin/dual-tunnel-probe --full

trap - ERR INT TERM
trap cleanup EXIT

echo 'SUCCESS: live server migrated to final architecture'
echo 'TCP: direct carriers; UDP: XUDP/VLESS; Mieru: MULTIPLEXING_OFF'
echo "Backup retained at $BK"
echo 'x-ui and public :443 were not modified.'
