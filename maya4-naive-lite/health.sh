#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=/etc/maya4-naive
fail=0
if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G='';R='';Y='';B='';N=''; fi
ok(){ printf '%b%-7s%b %s\n' "$G" OK "$N" "$*"; }
bad(){ printf '%b%-7s%b %s\n' "$R" FAIL "$N" "$*"; fail=1; }
warn(){ printf '%b%-7s%b %s\n' "$Y" WARN "$N" "$*"; }

http_once(){
  local port=$1 url=$2 expect=$3 out code time
  out=$(curl -4 -sS --socks5-hostname "127.0.0.1:$port" --connect-timeout 5 --max-time 10 \
    -o /dev/null -w '%{http_code} %{time_total}' "$url" 2>/dev/null || true)
  code=${out%% *}; time=${out#* }
  [[ "$code" =~ $expect ]] || return 1
  printf '%s %s' "$code" "$time"
}

udp_once(){
  local port=$1
  PROBE_SOCKS_PORT="$port" python3 <<'PY' >/dev/null 2>&1
import os,random,socket,struct
h='127.0.0.1'; p=int(os.environ['PROBE_SOCKS_PORT'])
def r(s,n):
 b=b''
 while len(b)<n:
  x=s.recv(n-len(b))
  if not x: raise RuntimeError
  b+=x
 return b
s=socket.create_connection((h,p),timeout=5); s.sendall(b'\x05\x01\x00')
if r(s,2)!=b'\x05\x00': raise RuntimeError
s.sendall(b'\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00')
_,rep,_,at=r(s,4)
if rep: raise RuntimeError
if at==1: relay=socket.inet_ntoa(r(s,4))
elif at==3: relay=r(s,r(s,1)[0]).decode()
elif at==4: relay=socket.inet_ntop(socket.AF_INET6,r(s,16))
else: raise RuntimeError
rp=struct.unpack('!H',r(s,2))[0]
if relay in ('0.0.0.0','::'): relay=h
q=random.randrange(65536)
dns=struct.pack('!HHHHHH',q,0x100,1,0,0,0)+b'\x07youtube\x03com\x00'+struct.pack('!HH',1,1)
pkt=b'\0\0\0\1'+socket.inet_aton('1.1.1.1')+struct.pack('!H',53)+dns
u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); u.settimeout(6)
u.sendto(pkt,(relay,rp)); data,_=u.recvfrom(4096)
if len(data)<12: raise RuntimeError
PY
}

echo 'MAYA4 NAIVE LITE — HEALTH'
if [[ -s "$ROOT/bundle.json" ]]; then
  printf 'Foreign : %s\n' "$(jq -r '.public_ip // "unknown"' "$ROOT/bundle.json")"
  printf 'Domain  : %s\n' "$(jq -r '.domain // "unknown"' "$ROOT/bundle.json")"
fi
echo

for s in maya4-naive-client maya4-xudp-router x-ui; do
  if systemctl is-active --quiet "$s.service" 2>/dev/null; then ok "$s"; else bad "$s"; fi
done

echo
r=$(http_once 7995 https://www.gstatic.com/generate_204 '^204$' || true)
[[ -n "$r" ]] && ok "Naive direct :7995 HTTP=204 time=${r#* }s" || bad 'Naive direct :7995 HTTP'

r=$(http_once 7996 https://www.gstatic.com/generate_204 '^204$' || true)
[[ -n "$r" ]] && ok "Naive full   :7996 HTTP=204 time=${r#* }s" || bad 'Naive full :7996 HTTP'

tg=0
for _ in 1 2 3; do
  http_once 7996 https://api.telegram.org/ '^(200|301|302)$' >/dev/null && tg=$((tg+1)) || true
  sleep .15
done
(( tg==3 )) && ok "Telegram :7996=$tg/3" || { ((tg>0)) && warn "Telegram :7996=$tg/3" || bad 'Telegram :7996=0/3'; }

ug=0
for _ in 1 2; do udp_once 7996 && ug=$((ug+1)) || true; sleep .15; done
(( ug==2 )) && ok "UDP/XUDP :7996=$ug/2" || { ((ug>0)) && warn "UDP/XUDP :7996=$ug/2" || bad 'UDP/XUDP :7996=0/2'; }

echo
mem=$(awk '/MemTotal:/ {printf "%.0f", $2/1024}' /proc/meminfo)
avail=$(awk '/MemAvailable:/ {printf "%.0f", $2/1024}' /proc/meminfo)
printf 'RAM total/available: %s MiB / %s MiB\n' "$mem" "$avail"

for s in maya4-naive-client maya4-xudp-router x-ui; do
  bytes=$(systemctl show "$s.service" -p MemoryCurrent --value 2>/dev/null || echo 0)
  if [[ "$bytes" =~ ^[0-9]+$ ]]; then
    printf '%-20s %6d MiB\n' "$s" "$((bytes/1024/1024))"
  fi
done

exit "$fail"
