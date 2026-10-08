#!/usr/bin/env bash
set -Eeuo pipefail

D=/etc/dual-trust-mieru/iran
MODE=${1:---quick}
ROLE_FILTER=${2:-all}
[[ "$MODE" == --quick || "$MODE" == --full ]] || { echo "usage: dual-health [--quick|--full] [all|trust|mieru|naive]" >&2; exit 2; }
[[ "$ROLE_FILTER" == all || "$ROLE_FILTER" == trust || "$ROLE_FILTER" == mieru || "$ROLE_FILTER" == naive ]] || { echo "invalid role" >&2; exit 2; }

if [[ -t 1 ]]; then
  G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; N=$'\e[0m'
else G=''; R=''; Y=''; C=''; B=''; N=''; fi

ok(){ printf '%b%-7s%b %s\n' "$G" 'OK' "$N" "$*"; }
bad(){ printf '%b%-7s%b %s\n' "$R" 'FAIL' "$N" "$*"; }
warn(){ printf '%b%-7s%b %s\n' "$Y" 'WARN' "$N" "$*"; }

http_once(){
  local port=$1 url=$2 expect_re=$3 out code time
  out=$(curl -4 -sS --socks5-hostname "127.0.0.1:$port" --connect-timeout 5 --max-time 10 \
    -o /dev/null -w '%{http_code} %{time_total}' "$url" 2>/dev/null || true)
  code=${out%% *}; time=${out#* }
  [[ "$code" =~ $expect_re ]] || return 1
  printf '%s %s' "$code" "$time"
}

udp_once(){
  local port=$1
  PROBE_SOCKS_PORT="$port" python3 <<'PY'
import os,random,socket,struct
h='127.0.0.1'; p=int(os.environ['PROBE_SOCKS_PORT'])
def recvn(s,n):
    b=b''
    while len(b)<n:
        x=s.recv(n-len(b))
        if not x: raise RuntimeError('SOCKS closed')
        b+=x
    return b
s=socket.create_connection((h,p),timeout=5)
s.sendall(b'\x05\x01\x00')
if recvn(s,2)!=b'\x05\x00': raise RuntimeError('SOCKS auth')
s.sendall(b'\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00')
_,rep,_,at=recvn(s,4)
if rep: raise RuntimeError(f'UDP ASSOCIATE reply={rep}')
if at==1: relay=socket.inet_ntoa(recvn(s,4))
elif at==3: relay=recvn(s,recvn(s,1)[0]).decode()
elif at==4: relay=socket.inet_ntop(socket.AF_INET6,recvn(s,16))
else: raise RuntimeError('bad ATYP')
rport=struct.unpack('!H',recvn(s,2))[0]
if relay in ('0.0.0.0','::'): relay=h
qid=random.randrange(65536)
qname=b''.join(bytes([len(x)])+x.encode() for x in 'youtube.com'.split('.'))+b'\0'
dns=struct.pack('!HHHHHH',qid,0x0100,1,0,0,0)+qname+struct.pack('!HH',1,1)
pkt=b'\0\0\0\1'+socket.inet_aton('1.1.1.1')+struct.pack('!H',53)+dns
u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); u.settimeout(6)
u.sendto(pkt,(relay,rport)); data,_=u.recvfrom(65535)
if len(data)<12: raise RuntimeError('short UDP reply')
PY
}

probe_http_label(){
  local label=$1 port=$2 result
  if result=$(http_once "$port" 'https://www.gstatic.com/generate_204' '^204$'); then
    ok "$label HTTP=${result%% *} time=${result#* }s"
    return 0
  fi
  bad "$label HTTP probe"
  return 1
}

probe_telegram(){
  local label=$1 port=$2 tries=${3:-3} i good=0 result total=''
  for i in $(seq 1 "$tries"); do
    if result=$(http_once "$port" 'https://api.telegram.org/' '^(200|301|302)$'); then
      good=$((good+1)); total+=" ${result#* }"
    fi
    sleep 0.15
  done
  if (( good == tries )); then ok "$label Telegram=$good/$tries"; return 0; fi
  if (( good > 0 )); then warn "$label Telegram=$good/$tries intermittent"; return 1; fi
  bad "$label Telegram=0/$tries"; return 1
}

probe_udp_label(){
  local label=$1 port=$2 tries=${3:-2} i good=0
  for i in $(seq 1 "$tries"); do udp_once "$port" >/dev/null 2>&1 && good=$((good+1)); sleep 0.15; done
  if (( good == tries )); then ok "$label UDP/XUDP=$good/$tries"; return 0; fi
  if (( good > 0 )); then warn "$label UDP/XUDP=$good/$tries intermittent"; return 1; fi
  bad "$label UDP/XUDP=0/$tries"; return 1
}

role_ip(){ local f=$1; [[ -s "$f" ]] && jq -r '.public_ip // "unknown"' "$f" 2>/dev/null || echo unknown; }

L3=/etc/dual-trust-mieru/lane3
if [[ -s "$L3/bundle.json" ]]; then
  printf '%b%s%b\n' "$B$C" 'TRIPLE TRUST / MIERU / NAIVE TUNNEL — HEALTH' "$N"
else
  printf '%b%s%b\n' "$B$C" 'DUAL MIERU TRUST TUNNEL — HEALTH' "$N"
fi
if [[ -s "$D/trust-bundle.json" ]]; then printf 'Trust foreign : %s\n' "$(role_ip "$D/trust-bundle.json")"; fi
if [[ -s "$D/mieru-bundle.json" ]]; then printf 'Mieru foreign : %s\n' "$(role_ip "$D/mieru-bundle.json")"; fi
if [[ -s "$L3/bundle.json" ]]; then printf 'Naive foreign : %s\n' "$(role_ip "$L3/bundle.json")"; fi

echo
printf '%bServices%b\n' "$B" "$N"
for s in dual-trust-client dual-mieru-carrier dual-xudp-bridge dual-dispatcher x-ui; do
  if systemctl is-active --quiet "$s.service" 2>/dev/null; then ok "$s"; else bad "$s"; fi
done
if [[ -s "$L3/bundle.json" ]]; then
  for s in lane3-naive-client lane3-xudp-router; do
    if systemctl is-active --quiet "$s.service" 2>/dev/null; then ok "$s"; else bad "$s"; fi
  done
fi

echo
printf '%bPaths%b\n' "$B" "$N"
fail=0
if [[ "$ROLE_FILTER" == all || "$ROLE_FILTER" == trust ]]; then
  probe_http_label 'Trust direct :7993' 7993 || fail=1
  probe_http_label 'Trust TCP    :7991' 7991 || fail=1
  probe_telegram 'Trust path   :7991' 7991 3 || fail=1
  if [[ "$MODE" == --full ]]; then probe_udp_label 'Trust path   :7991' 7991 2 || fail=1; fi
fi
if [[ "$ROLE_FILTER" == all || "$ROLE_FILTER" == mieru ]]; then
  probe_http_label 'Mieru direct :7994' 7994 || fail=1
  probe_http_label 'Mieru TCP    :7992' 7992 || fail=1
  probe_telegram 'Mieru path   :7992' 7992 3 || fail=1
  if [[ "$MODE" == --full ]]; then probe_udp_label 'Mieru path   :7992' 7992 2 || fail=1; fi
fi
if [[ "$ROLE_FILTER" == all || "$ROLE_FILTER" == naive ]]; then
  if [[ -s "$L3/bundle.json" ]]; then
    probe_http_label 'Naive direct :7995' 7995 || fail=1
    probe_http_label 'Naive TCP    :7996' 7996 || fail=1
    probe_telegram 'Naive path   :7996' 7996 3 || fail=1
    if [[ "$MODE" == --full ]]; then probe_udp_label 'Naive path   :7996' 7996 2 || fail=1; fi
  elif [[ "$ROLE_FILTER" == naive ]]; then
    bad 'Naive role is not configured'
    fail=1
  fi
fi
if [[ "$ROLE_FILTER" == all ]]; then
  probe_http_label 'Unified entry:7990' 7990 || fail=1
  probe_telegram 'Unified entry:7990' 7990 3 || fail=1
  if [[ "$MODE" == --full ]]; then probe_udp_label 'Unified entry:7990' 7990 2 || fail=1; fi
fi

exit "$fail"
