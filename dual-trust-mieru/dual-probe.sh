#!/usr/bin/env bash
set -Eeuo pipefail
MODE=${1:---full}
ENTRY_PORT=${ENTRY_PORT:-7990}
TRUST_PORT=${TRUST_XUDP_PORT:-7991}
MIERU_PORT=${MIERU_XUDP_PORT:-7992}

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

probe_http(){
  local port=$1 label=$2 url=$3 expect=${4:-any} code
  code=$(curl -4 -sS -L --socks5-hostname "127.0.0.1:$port" --connect-timeout 8 --max-time 25 -o /dev/null -w '%{http_code}' "$url" || true)
  if [[ "$expect" == 204 ]]; then
    [[ "$code" == 204 ]] || die "$label failed HTTP=${code:-000}"
  else
    [[ "$code" =~ ^[234][0-9][0-9]$ ]] || die "$label failed HTTP=${code:-000}"
  fi
  log "$label = OK (HTTP=$code)"
}

probe_udp(){
  local port=$1 label=$2
  PROBE_SOCKS_PORT=$port PROBE_LABEL=$label python3 <<'PY'
import os,random,socket,struct,time
h='127.0.0.1'; p=int(os.environ['PROBE_SOCKS_PORT']); label=os.environ['PROBE_LABEL']
def recvn(s,n):
    b=b''
    while len(b)<n:
        x=s.recv(n-len(b))
        if not x: raise RuntimeError('SOCKS closed')
        b+=x
    return b
s=socket.create_connection((h,p),timeout=5); s.sendall(b'\x05\x01\x00')
if recvn(s,2)!=b'\x05\x00': raise RuntimeError('SOCKS auth failed')
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
u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); u.settimeout(8); t=time.time(); u.sendto(pkt,(relay,rport)); data,_=u.recvfrom(65535)
pos=4; rat=data[3]
if rat==1: pos+=4
elif rat==3: pos+=1+data[pos]
elif rat==4: pos+=16
else: raise RuntimeError('bad reply ATYP')
pos+=2; d=data[pos:]
if len(d)<12: raise RuntimeError('short DNS reply')
rid,flags=struct.unpack('!HH',d[:4])
if rid!=qid or not(flags&0x8000): raise RuntimeError('invalid DNS reply')
print(f'[{time.strftime("%F %T")}] {label} UDP/XUDP = OK ({time.time()-t:.3f}s, rcode={flags&15})')
PY
}

probe_transfer(){
  local port=$1 label=$2 code size secs
  read -r code size secs < <(curl -4 -sS -L --socks5-hostname "127.0.0.1:$port" --connect-timeout 8 --max-time 30 \
    -o /dev/null -w '%{http_code} %{size_download} %{time_total}\n' 'https://speed.cloudflare.com/__down?bytes=1000000' || echo '000 0 99')
  [[ "$code" == 200 && "$size" =~ ^[0-9]+$ && "$size" -ge 750000 ]] || die "$label transfer failed HTTP=$code bytes=$size time=$secs"
  log "$label transfer = OK (${size} bytes in ${secs}s)"
}

for p in "$ENTRY_PORT" "$TRUST_PORT" "$MIERU_PORT"; do
  ss -H -ltn "sport = :$p" 2>/dev/null | grep -q . || die "local SOCKS TCP/$p not listening"
done

log "Forced Trust XUDP path"
probe_http "$TRUST_PORT" "TRUST gstatic" https://www.gstatic.com/generate_204 204
log "Forced Mieru XUDP path"
probe_http "$MIERU_PORT" "MIERU gstatic" https://www.gstatic.com/generate_204 204
log "Dispatcher path"
probe_http "$ENTRY_PORT" "DUAL gstatic" https://www.gstatic.com/generate_204 204

if [[ "$MODE" == "--quick" ]]; then
  log "SUCCESS: both forced paths and dispatcher passed quick probe"
  exit 0
fi
[[ "$MODE" == "--full" ]] || die "usage: $0 [--quick|--full]"

for spec in "$TRUST_PORT:TRUST" "$MIERU_PORT:MIERU"; do
  p=${spec%%:*}; n=${spec#*:}
  probe_http "$p" "$n YouTube" https://www.youtube.com/ any
  probe_http "$p" "$n ytimg" https://i.ytimg.com/ any
  probe_http "$p" "$n Instagram" https://www.instagram.com/ any
  probe_transfer "$p" "$n"
  probe_udp "$p" "$n"
done
probe_udp "$ENTRY_PORT" "DUAL"

log "Observing dispatcher egress rotation (informational)"
for i in $(seq 1 8); do
  ip=$(curl -4 -sS --socks5-hostname "127.0.0.1:$ENTRY_PORT" --connect-timeout 8 --max-time 15 https://api.ipify.org || true)
  printf 'dispatch_%02d=%s\n' "$i" "${ip:-FAILED}"
done
log "SUCCESS: Trust + Mieru + dual XUDP full probe passed"
