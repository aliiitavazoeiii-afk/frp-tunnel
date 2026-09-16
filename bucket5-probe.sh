#!/usr/bin/env bash
set -Eeuo pipefail

P=anytls-tunnel
C=/etc/$P
E=${BUCKET5_ENV:-$C/bucket5.env}
M=/usr/local/bin/mihomo-$P
X=/usr/local/lib/$P/xray-v26.3.27
NODE=${1:-}
MPORT=${BUCKET5_PROBE_MIHOMO_PORT:-17890}
XPORT=${BUCKET5_PROBE_XRAY_PORT:-17891}
XUDP_SERVER_PORT=${XUDP_SERVER_PORT:-2443}

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ "$NODE" =~ ^F[1-5]$ ]] || die "usage: anytls-bucket5-probe F1|F2|F3|F4|F5"
[[ -f "$E" ]] || die "missing $E"
[[ -x "$M" ]] || die "missing Mihomo"
[[ -x "$X" ]] || die "missing Xray"
[[ -f "$C/xudp-bridge.json" ]] || die "missing XUDP bridge config"
source "$E"

idx=${NODE#F}
for suffix in ADDR TYPE COVER ANYTLS LAYER; do
  var="F${idx}_${suffix}"
  [[ -n "${!var:-}" ]] || die "missing $var"
done
addr_var="F${idx}_ADDR"; type_var="F${idx}_TYPE"; cover_var="F${idx}_COVER"
pass_var="F${idx}_ANYTLS"; layer_var="F${idx}_LAYER"
ADDR=${!addr_var}; TYPE=${!type_var}; COVER=${!cover_var}; PASS=${!pass_var}; LAYER=${!layer_var}
[[ "$TYPE" == shadow || "$TYPE" == restls ]] || die "bad type $TYPE"

XUDP_UUID=$(jq -r '.outbounds[]? | select((.tag // "") | startswith("xudp-inner")) | .settings.id // empty' "$C/xudp-bridge.json" | head -n1)
[[ "$XUDP_UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || die "cannot read XUDP UUID"

TMP=$(mktemp -d /tmp/anytls-bucket5-probe.XXXXXX)
MPID=""; XPID=""
cleanup(){
  set +e
  [[ -n "$XPID" ]] && kill "$XPID" 2>/dev/null
  [[ -n "$MPID" ]] && kill "$MPID" 2>/dev/null
  [[ -n "$XPID" ]] && wait "$XPID" 2>/dev/null
  [[ -n "$MPID" ]] && wait "$MPID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

for p in "$MPORT" "$XPORT"; do
  ss -H -ltn "sport = :$p" 2>/dev/null | grep -q . && die "probe port $p is busy"
done

log "$NODE: TCP/443 reachability"
timeout 6 bash -c "exec 3<>/dev/tcp/${ADDR}/443" 2>/dev/null || die "$NODE TCP/443 unreachable"

cat >"$TMP/mihomo.yaml" <<EOF
mode: rule
log-level: warning
ipv6: false
listeners:
  - name: probe-socks
    type: socks
    listen: 127.0.0.1
    port: $MPORT
    udp: true
    proxy: candidate
proxies:
  - name: candidate
    type: anytls
    server: "$ADDR"
    port: 443
    password: "$PASS"
    tls: true
    sni: "$COVER"
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: false
    idle-session-check-interval: 30
    idle-session-timeout: 60
    min-idle-session: 1
EOF
if [[ "$TYPE" == shadow ]]; then
cat >>"$TMP/mihomo.yaml" <<EOF
    shadow-tls-opts:
      version: 3
      password: "$LAYER"
EOF
else
cat >>"$TMP/mihomo.yaml" <<EOF
    restls-opts:
      password: "$LAYER"
      version-hint: tls13
EOF
fi
cat >>"$TMP/mihomo.yaml" <<'EOF'
rules:
  - MATCH,candidate
EOF

"$M" -t -d "$TMP" -f "$TMP/mihomo.yaml" >/dev/null
"$M" -d "$TMP" -f "$TMP/mihomo.yaml" >"$TMP/mihomo.log" 2>&1 &
MPID=$!
for _ in $(seq 1 40); do ss -H -ltn "sport = :$MPORT" 2>/dev/null | grep -q . && break; sleep 0.2; done
ss -H -ltn "sport = :$MPORT" | grep -q . || { cat "$TMP/mihomo.log" >&2 || true; die "probe Mihomo failed"; }

cat >"$TMP/xudp.json" <<EOF
{
  "log":{"loglevel":"warning"},
  "inbounds":[{"tag":"probe-in","listen":"127.0.0.1","port":$XPORT,"protocol":"socks","settings":{"auth":"noauth","udp":true}}],
  "outbounds":[
    {"tag":"xudp-inner","protocol":"vless","settings":{"address":"127.0.0.1","port":$XUDP_SERVER_PORT,"id":"$XUDP_UUID","encryption":"none"},"streamSettings":{"network":"raw","sockopt":{"dialerProxy":"carrier"}},"mux":{"enabled":true,"concurrency":-1,"xudpConcurrency":16,"xudpProxyUDP443":"allow"}},
    {"tag":"carrier","protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":$MPORT,"users":[]}]}}
  ],
  "routing":{"domainStrategy":"AsIs","rules":[{"type":"field","inboundTag":["probe-in"],"outboundTag":"xudp-inner"}]}
}
EOF

"$X" run -test -c "$TMP/xudp.json" >/dev/null
"$X" run -c "$TMP/xudp.json" >"$TMP/xray.log" 2>&1 &
XPID=$!
for _ in $(seq 1 40); do ss -H -ltn "sport = :$XPORT" 2>/dev/null | grep -q . && break; sleep 0.2; done
ss -H -ltn "sport = :$XPORT" | grep -q . || { cat "$TMP/xray.log" >&2 || true; die "probe Xray failed"; }

probe_http(){
  local label=$1 url=$2 mode=$3 code
  code=$(curl -4 -sS -L --socks5-hostname "127.0.0.1:$XPORT" --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' "$url" || true)
  if [[ "$mode" == 204 ]]; then [[ "$code" == 204 ]] || die "$NODE $label failed HTTP=${code:-000}";
  else [[ "$code" =~ ^[234][0-9][0-9]$ ]] || die "$NODE $label failed HTTP=${code:-000}"; fi
  log "$NODE $label = OK (HTTP=$code)"
}

probe_http gstatic https://www.gstatic.com/generate_204 204
probe_http youtube https://www.youtube.com/ any
probe_http ytimg https://i.ytimg.com/ any
probe_http instagram https://www.instagram.com/ any

read -r code size secs < <(curl -4 -sS -L --socks5-hostname "127.0.0.1:$XPORT" --connect-timeout 8 --max-time 25 -o /dev/null -w '%{http_code} %{size_download} %{time_total}\n' 'https://speed.cloudflare.com/__down?bytes=1000000' || echo '000 0 99')
[[ "$code" == 200 && "$size" =~ ^[0-9]+$ && "$size" -ge 750000 ]] || die "$NODE sustained transfer failed HTTP=$code bytes=$size time=$secs"
log "$NODE sustained transfer = OK (${size} bytes in ${secs}s)"

PROBE_XRAY_PORT="$XPORT" python3 <<'PY'
import os,random,socket,struct,time
h='127.0.0.1'; p=int(os.environ['PROBE_XRAY_PORT'])
def r(s,n):
    b=b''
    while len(b)<n:
        x=s.recv(n-len(b))
        if not x: raise RuntimeError('SOCKS closed')
        b+=x
    return b
s=socket.create_connection((h,p),timeout=5); s.sendall(b'\x05\x01\x00')
if r(s,2)!=b'\x05\x00': raise RuntimeError('SOCKS auth')
s.sendall(b'\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00'); _,rep,_,at=r(s,4)
if rep: raise RuntimeError(f'UDP ASSOCIATE {rep}')
if at==1: relay=socket.inet_ntoa(r(s,4))
elif at==3: relay=r(s,r(s,1)[0]).decode()
elif at==4: relay=socket.inet_ntop(socket.AF_INET6,r(s,16))
else: raise RuntimeError('ATYP')
port=struct.unpack('!H',r(s,2))[0]
if relay in ('0.0.0.0','::'): relay=h
qid=random.randrange(65536); q=b''.join(bytes([len(x)])+x.encode() for x in 'youtube.com'.split('.'))+b'\0'; dns=struct.pack('!HHHHHH',qid,0x0100,1,0,0,0)+q+struct.pack('!HH',1,1)
pkt=b'\0\0\0\1'+socket.inet_aton('1.1.1.1')+struct.pack('!H',53)+dns
u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); u.settimeout(8); t=time.time(); u.sendto(pkt,(relay,port)); data,_=u.recvfrom(65535)
pos=4; at=data[3]
if at==1: pos+=4
elif at==3: pos+=1+data[pos]
elif at==4: pos+=16
else: raise RuntimeError('reply ATYP')
pos+=2; d=data[pos:]
if len(d)<12: raise RuntimeError('short DNS')
rid,flags=struct.unpack('!HH',d[:4])
if rid!=qid or not(flags&0x8000): raise RuntimeError('bad DNS')
print(f'UDP XUDP PROBE = OK ({time.time()-t:.3f}s, rcode={flags&15})')
PY

log "SUCCESS: $NODE passed full TCP + AnyTLS + XUDP + app + transfer + UDP probe"
