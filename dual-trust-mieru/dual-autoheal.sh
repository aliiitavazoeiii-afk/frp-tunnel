#!/usr/bin/env bash
set -Eeuo pipefail
D=/etc/dual-trust-mieru/iran
STATE=/var/lib/dual-trust-mieru/autoheal
LOCK=/run/dual-trust-mieru-autoheal.lock
LOG_TAG=dual-autoheal
THRESHOLD=${AUTOHEAL_THRESHOLD:-2}
BRIDGE_THRESHOLD=${AUTOHEAL_BRIDGE_THRESHOLD:-3}
mkdir -p "$STATE"; chmod 0700 "$STATE"
exec 9>"$LOCK"; flock -n 9 || exit 0
log(){ logger -t "$LOG_TAG" -- "$*"; printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
printf '%s\n' "$(date -Is)" > "$STATE/last-run"

probe_http(){
  local port=$1 code url
  if (( RANDOM % 2 )); then url='https://www.gstatic.com/generate_204'; else url='https://cp.cloudflare.com/'; fi
  code=$(curl -4 -sS --socks5-hostname "127.0.0.1:$port" --connect-timeout 4 --max-time 7 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
  [[ "$code" =~ ^(200|204)$ ]]
}

probe_udp(){
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
s=socket.create_connection((h,p),timeout=4); s.sendall(b'\x05\x01\x00')
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
q=random.randrange(65536); name=b'\x07youtube\x03com\x00'; dns=struct.pack('!HHHHHH',q,0x100,1,0,0,0)+name+struct.pack('!HH',1,1)
pkt=b'\0\0\0\1'+socket.inet_aton('1.1.1.1')+struct.pack('!H',53)+dns
u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); u.settimeout(5); u.sendto(pkt,(relay,rp)); data,_=u.recvfrom(4096)
if len(data)<12: raise RuntimeError
PY
}
get_count(){ local f=$1 n=0; [[ -s "$f" ]] && read -r n < "$f" || true; [[ "$n" =~ ^[0-9]+$ ]] || n=0; printf '%s' "$n"; }
set_count(){ printf '%s\n' "$2" > "$1"; }

heal_carrier(){
  local name=$1 port=$2 svc=$3 f="$STATE/${name}.failcount" n
  if probe_http "$port"; then set_count "$f" 0; return 0; fi
  n=$(get_count "$f"); n=$((n+1)); set_count "$f" "$n"; log "$name direct unhealthy cycle=$n/$THRESHOLD"
  (( n >= THRESHOLD )) || return 1
  log "$name restarting only $svc"; systemctl restart "$svc"; sleep 4
  if probe_http "$port"; then set_count "$f" 0; log "$name recovered after selective carrier restart"; return 0; fi
  set_count "$f" 1; log "$name still unhealthy after carrier restart"; return 1
}

trust_ok=0; mieru_ok=0; naive_ok=0
heal_carrier trust 7993 dual-trust-client.service && trust_ok=1 || true
heal_carrier mieru 7994 dual-mieru-carrier.service && mieru_ok=1 || true
if [[ -s /etc/dual-trust-mieru/lane3/bundle.json ]]; then
  heal_carrier naive 7995 lane3-naive-client.service && naive_ok=1 || true

  # Naive owns a dedicated XUDP router, so a UDP-only Naive failure must never
  # restart the shared Trust/Mieru bridge.
  nf="$STATE/naive-xudp.failcount"
  if (( naive_ok )); then
    if probe_udp 7996; then
      set_count "$nf" 0
    else
      n=$(get_count "$nf"); n=$((n+1)); set_count "$nf" "$n"
      log "naive UDP/XUDP degraded cycle=$n/$BRIDGE_THRESHOLD"
      if (( n >= BRIDGE_THRESHOLD )); then
        log 'naive UDP/XUDP repeatedly failed; restarting only lane3-xudp-router.service'
        systemctl restart lane3-xudp-router.service; sleep 3
        if probe_udp 7996; then
          set_count "$nf" 0; log 'naive UDP/XUDP recovered'
        else
          set_count "$nf" 1; log 'naive UDP/XUDP still degraded'
        fi
      fi
    fi
  fi
fi

# TCP on 7991/7992 is intentionally direct-carrier traffic. It is NOT an XUDP test.
# Therefore only UDP probes are allowed to influence XUDP/bridge diagnosis.
if (( trust_ok && mieru_ok )); then
  t_udp=0; m_udp=0
  probe_udp 7991 && t_udp=1 || true
  probe_udp 7992 && m_udp=1 || true
  [[ $t_udp == 1 ]] || log 'trust UDP/XUDP degraded; shared bridge not restarted for a one-role failure'
  [[ $m_udp == 1 ]] || log 'mieru UDP/XUDP degraded; shared bridge not restarted for a one-role failure'
  bf="$STATE/bridge.failcount"
  if (( t_udp == 0 && m_udp == 0 )); then
    n=$(get_count "$bf"); n=$((n+1)); set_count "$bf" "$n"; log "both UDP/XUDP paths failed cycle=$n/$BRIDGE_THRESHOLD"
    if (( n >= BRIDGE_THRESHOLD )); then
      log 'both role UDP paths repeatedly failed; restarting shared dual-xudp-bridge once'
      systemctl restart dual-xudp-bridge.service; sleep 3
      if probe_udp 7991 && probe_udp 7992; then set_count "$bf" 0; log 'shared UDP/XUDP recovered'; else set_count "$bf" 1; log 'shared UDP/XUDP still degraded'; fi
    fi
  else
    set_count "$bf" 0
  fi
fi
