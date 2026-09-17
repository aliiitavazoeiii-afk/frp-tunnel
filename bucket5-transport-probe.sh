#!/usr/bin/env bash
set -Eeuo pipefail

P=anytls-tunnel
C=/etc/$P
M=/usr/local/bin/mihomo-$P
X=/usr/local/lib/$P/xray-v26.3.27
CONF=${BUCKET5_TRANSPORT_CONFIG:-$C/bucket5-transports-canary.json}
NODE=${1:-}
CARRIER=${2:-}
XUDP_SERVER_PORT=${XUDP_SERVER_PORT:-2443}
START_TS=$(date +%s)
STAGE=init

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
stage(){ STAGE=$1; echo "STAGE=$STAGE"; }
pick_port(){ python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ "$NODE" =~ ^F[1-5]$ ]] || die "usage: anytls-bucket5-transport-probe F1..F5 CARRIER"
[[ "$CARRIER" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid carrier name"
[[ -f "$CONF" ]] || die "missing $CONF"
[[ -x "$M" && -x "$X" ]] || die "required Mihomo/Xray binaries missing"
[[ -f "$C/xudp-bridge.json" ]] || die "missing production XUDP config"
command -v jq >/dev/null 2>&1 || die "jq missing"

base=".nodes[\"$NODE\"].carriers[\"$CARRIER\"]"
KIND=$(jq -r "$base.kind // empty" "$CONF")
ADDR=$(jq -r "$base.addr // empty" "$CONF")
PORT=$(jq -r "$base.port // empty" "$CONF")
[[ -n "$KIND" && -n "$ADDR" && "$PORT" =~ ^[0-9]+$ ]] || die "carrier not found/incomplete: $NODE/$CARRIER"

XUDP_UUID=$(jq -r '.outbounds[]? | select((.tag // "") | startswith("xudp-inner")) | .settings.id // empty' "$C/xudp-bridge.json" | head -n1)
[[ "$XUDP_UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || die "cannot read XUDP UUID"

TMP=$(mktemp -d /tmp/bucket5-transport-probe.XXXXXX)
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
MPORT=$(pick_port); XPORT=$(pick_port)
while [[ "$XPORT" == "$MPORT" ]]; do XPORT=$(pick_port); done

stage tcp
log "$NODE/$CARRIER: raw TCP ${ADDR}:${PORT}"
timeout 6 bash -c "exec 3<>/dev/tcp/${ADDR}/${PORT}" 2>/dev/null || die "$NODE/$CARRIER TCP unreachable"

stage carrier_config
cat >"$TMP/mihomo.yaml" <<EOF2
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
EOF2

case "$KIND" in
  anytls-restls)
    PASS=$(jq -r "$base.password // empty" "$CONF")
    LAYER=$(jq -r "$base.layer // empty" "$CONF")
    COVER=$(jq -r "$base.cover // empty" "$CONF")
    TLSVER=$(jq -r "$base.tls_version // \"tls13\"" "$CONF")
    [[ -n "$PASS" && -n "$LAYER" && -n "$COVER" ]] || die "incomplete restls carrier"
    cat >>"$TMP/mihomo.yaml" <<EOF2
  - name: candidate
    type: anytls
    server: "$ADDR"
    port: $PORT
    password: "$PASS"
    tls: true
    sni: "$COVER"
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: false
    idle-session-check-interval: 30
    idle-session-timeout: 60
    min-idle-session: 1
    restls-opts:
      password: "$LAYER"
      version-hint: $TLSVER
EOF2
    ;;
  anytls-shadow)
    PASS=$(jq -r "$base.password // empty" "$CONF")
    LAYER=$(jq -r "$base.layer // empty" "$CONF")
    COVER=$(jq -r "$base.cover // empty" "$CONF")
    [[ -n "$PASS" && -n "$LAYER" && -n "$COVER" ]] || die "incomplete shadow carrier"
    cat >>"$TMP/mihomo.yaml" <<EOF2
  - name: candidate
    type: anytls
    server: "$ADDR"
    port: $PORT
    password: "$PASS"
    tls: true
    sni: "$COVER"
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: false
    idle-session-check-interval: 30
    idle-session-timeout: 60
    min-idle-session: 1
    shadow-tls-opts:
      version: 3
      password: "$LAYER"
EOF2
    ;;
  vless-reality)
    UUID=$(jq -r "$base.uuid // empty" "$CONF")
    SNI=$(jq -r "$base.server_name // empty" "$CONF")
    PUB=$(jq -r "$base.public_key // empty" "$CONF")
    SID=$(jq -r "$base.short_id // empty" "$CONF")
    FLOW=$(jq -r "$base.flow // \"xtls-rprx-vision\"" "$CONF")
    [[ -n "$UUID" && -n "$SNI" && -n "$PUB" && -n "$SID" ]] || die "incomplete reality carrier"
    cat >>"$TMP/mihomo.yaml" <<EOF2
  - name: candidate
    type: vless
    server: "$ADDR"
    port: $PORT
    uuid: "$UUID"
    flow: "$FLOW"
    udp: true
    tls: true
    network: tcp
    servername: "$SNI"
    client-fingerprint: chrome
    skip-cert-verify: false
    reality-opts:
      public-key: "$PUB"
      short-id: "$SID"
EOF2
    ;;
  *) die "unsupported carrier kind: $KIND" ;;
esac
cat >>"$TMP/mihomo.yaml" <<'EOF2'
rules:
  - MATCH,candidate
EOF2

"$M" -t -d "$TMP" -f "$TMP/mihomo.yaml" >/dev/null || die "carrier candidate config invalid"
"$M" -d "$TMP" -f "$TMP/mihomo.yaml" >"$TMP/mihomo.log" 2>&1 & MPID=$!
for _ in $(seq 1 40); do ss -H -ltn "sport = :$MPORT" 2>/dev/null | grep -q . && break; sleep 0.2; done
ss -H -ltn "sport = :$MPORT" | grep -q . || { tail -n 80 "$TMP/mihomo.log" >&2 || true; die "probe Mihomo failed"; }

stage carrier
code=$(curl -4 -sS -L --socks5-hostname "127.0.0.1:$MPORT" --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 || true)
[[ "$code" == 204 ]] || { tail -n 80 "$TMP/mihomo.log" >&2 || true; die "$NODE/$CARRIER direct carrier failed HTTP=${code:-000}"; }
log "$NODE/$CARRIER direct carrier = OK"

stage xudp_start
cat >"$TMP/xudp.json" <<EOF2
{
  "log":{"loglevel":"warning"},
  "inbounds":[{"tag":"probe-in","listen":"127.0.0.1","port":$XPORT,"protocol":"socks","settings":{"auth":"noauth","udp":true}}],
  "outbounds":[
    {"tag":"xudp-inner","protocol":"vless","settings":{"address":"127.0.0.1","port":$XUDP_SERVER_PORT,"id":"$XUDP_UUID","encryption":"none"},"streamSettings":{"network":"raw","sockopt":{"dialerProxy":"carrier"}},"mux":{"enabled":true,"concurrency":-1,"xudpConcurrency":16,"xudpProxyUDP443":"allow"}},
    {"tag":"carrier","protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":$MPORT,"users":[]}]}}
  ],
  "routing":{"domainStrategy":"AsIs","rules":[{"type":"field","inboundTag":["probe-in"],"outboundTag":"xudp-inner"}]}
}
EOF2
"$X" run -test -c "$TMP/xudp.json" >/dev/null || die "probe XUDP config invalid"
"$X" run -c "$TMP/xudp.json" >"$TMP/xray.log" 2>&1 & XPID=$!
for _ in $(seq 1 40); do ss -H -ltn "sport = :$XPORT" 2>/dev/null | grep -q . && break; sleep 0.2; done
ss -H -ltn "sport = :$XPORT" | grep -q . || { tail -n 80 "$TMP/xray.log" >&2 || true; die "probe Xray failed"; }

probe_http(){
  local label=$1 url=$2 mode=$3 code
  stage "xudp_${label}"
  code=$(curl -4 -sS -L --socks5-hostname "127.0.0.1:$XPORT" --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' "$url" || true)
  if [[ "$mode" == 204 ]]; then [[ "$code" == 204 ]] || die "$NODE/$CARRIER $label failed HTTP=${code:-000}";
  else [[ "$code" =~ ^[234][0-9][0-9]$ ]] || die "$NODE/$CARRIER $label failed HTTP=${code:-000}"; fi
  log "$NODE/$CARRIER $label = OK (HTTP=$code)"
}

probe_http gstatic https://www.gstatic.com/generate_204 204
probe_http youtube https://www.youtube.com/ any
probe_http ytimg https://i.ytimg.com/ any
probe_http instagram https://www.instagram.com/ any

stage transfer
read -r code size secs < <(curl -4 -sS -L --socks5-hostname "127.0.0.1:$XPORT" --connect-timeout 8 --max-time 25 -o /dev/null -w '%{http_code} %{size_download} %{time_total}\n' 'https://speed.cloudflare.com/__down?bytes=1000000' || echo '000 0 99')
[[ "$code" == 200 && "$size" =~ ^[0-9]+$ && "$size" -ge 750000 ]] || die "$NODE/$CARRIER sustained transfer failed HTTP=$code bytes=$size time=$secs"
log "$NODE/$CARRIER sustained transfer = OK (${size} bytes in ${secs}s)"

stage udp
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

stage success
ELAPSED=$(( $(date +%s) - START_TS ))
log "SUCCESS: $NODE/$CARRIER passed TCP + direct carrier + XUDP + app + transfer + UDP (${ELAPSED}s)"
