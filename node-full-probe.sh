#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="anytls-tunnel"
CONFIG_DIR="/etc/${PROJECT}"
MIHOMO="/usr/local/bin/mihomo-${PROJECT}"
XRAY="/usr/local/lib/${PROJECT}/xray-v26.3.27"
DEPLOY_ENV="${CONFIG_DIR}/deploy.env"
SHARED_ENV="${CONFIG_DIR}/shared-node.env"
PROBE_MIHOMO_PORT="${PROBE_MIHOMO_PORT:-17890}"
PROBE_XRAY_PORT="${PROBE_XRAY_PORT:-17891}"
XUDP_SERVER_PORT="${XUDP_SERVER_PORT:-2443}"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
NODE="${1:-}"
[[ "$NODE" == "a" || "$NODE" == "b" || "$NODE" == "shared" ]] || die "usage: anytls-node-full-probe a|b|shared"
[[ -f "$DEPLOY_ENV" ]] || die "missing $DEPLOY_ENV"
[[ -x "$MIHOMO" ]] || die "missing Mihomo"
[[ -x "$XRAY" ]] || die "missing Xray"
[[ -f "${CONFIG_DIR}/xudp-bridge.json" ]] || die "missing XUDP bridge config"
# shellcheck disable=SC1090
source "$DEPLOY_ENV"

case "$NODE" in
  a)
    NAME="foreign-a-shadowtls"; ADDR="$NODE_A_ADDR"; COVER="$COVER_HOST_A"; PASS="$ANYTLS_PASS_A"; LAYER="$SHADOWTLS_PASS_A"; KIND="shadow"
    ;;
  b)
    NAME="foreign-b-restls"; ADDR="$NODE_B_ADDR"; COVER="$COVER_HOST_B"; PASS="$ANYTLS_PASS_B"; LAYER="$RESTLS_PASS_B"; KIND="restls"
    ;;
  shared)
    [[ -f "$SHARED_ENV" ]] || die "missing $SHARED_ENV"
    # shellcheck disable=SC1090
    source "$SHARED_ENV"
    NAME="foreign-shared-shadowtls"; ADDR="$SHARED_ADDR"; COVER="$SHARED_COVER"; PASS="$SHARED_ANYTLS_PASS"; LAYER="$SHARED_SHADOWTLS_PASS"; KIND="shadow"
    ;;
esac

for v in NAME ADDR COVER PASS LAYER KIND; do [[ -n "${!v:-}" ]] || die "missing $v for node $NODE"; done
XUDP_UUID=$(jq -r '.outbounds[]? | select(.tag=="xudp-inner") | .settings.id // empty' "${CONFIG_DIR}/xudp-bridge.json" | head -n1)
[[ "$XUDP_UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || die "invalid XUDP UUID"

TMP=$(mktemp -d /tmp/anytls-node-probe.XXXXXX)
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
for p in "$PROBE_MIHOMO_PORT" "$PROBE_XRAY_PORT"; do
  ss -H -ltn "sport = :$p" 2>/dev/null | grep -q . && die "probe port $p already in use"
done

log "$NAME: TCP/443 preflight"
timeout 6 bash -c "exec 3<>/dev/tcp/${ADDR}/443" 2>/dev/null || die "$NAME TCP/443 unreachable"

MCONF="$TMP/mihomo.yaml"
cat >"$MCONF" <<EOF
mode: rule
log-level: warning
ipv6: false
listeners:
  - name: node-probe-socks
    type: socks
    listen: 127.0.0.1
    port: ${PROBE_MIHOMO_PORT}
    udp: true
    users: []
proxies:
  - name: candidate
    type: anytls
    server: "${ADDR}"
    port: 443
    password: "${PASS}"
    tls: true
    sni: "${COVER}"
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: false
    idle-session-check-interval: 30
    idle-session-timeout: 60
    min-idle-session: 1
EOF
if [[ "$KIND" == shadow ]]; then
cat >>"$MCONF" <<EOF
    shadow-tls-opts:
      version: 3
      password: "${LAYER}"
EOF
else
cat >>"$MCONF" <<EOF
    restls-opts:
      password: "${LAYER}"
      version-hint: tls13
EOF
fi
cat >>"$MCONF" <<'EOF'
rules:
  - MATCH,candidate
EOF

"$MIHOMO" -t -d "$TMP" -f "$MCONF" >/dev/null
"$MIHOMO" -d "$TMP" -f "$MCONF" >"$TMP/mihomo.log" 2>&1 & MPID=$!
for _ in $(seq 1 40); do ss -H -ltn "sport = :$PROBE_MIHOMO_PORT" 2>/dev/null | grep -q . && break; sleep 0.2; done
ss -H -ltn "sport = :$PROBE_MIHOMO_PORT" | grep -q . || { cat "$TMP/mihomo.log" >&2 || true; die "temporary Mihomo probe failed"; }

XCONF="$TMP/xudp.json"
cat >"$XCONF" <<EOF
{
  "log":{"loglevel":"warning"},
  "inbounds":[{"tag":"probe-in","listen":"127.0.0.1","port":${PROBE_XRAY_PORT},"protocol":"socks","settings":{"auth":"noauth","udp":true}}],
  "outbounds":[
    {"tag":"xudp-inner","protocol":"vless","settings":{"address":"127.0.0.1","port":${XUDP_SERVER_PORT},"id":"${XUDP_UUID}","encryption":"none"},"streamSettings":{"network":"raw","sockopt":{"dialerProxy":"candidate-carrier"}},"mux":{"enabled":true,"concurrency":-1,"xudpConcurrency":16,"xudpProxyUDP443":"allow"}},
    {"tag":"candidate-carrier","protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":${PROBE_MIHOMO_PORT},"users":[]}]}}
  ],
  "routing":{"domainStrategy":"AsIs","rules":[{"type":"field","inboundTag":["probe-in"],"outboundTag":"xudp-inner"}]}
}
EOF
"$XRAY" run -test -c "$XCONF" >/dev/null
"$XRAY" run -c "$XCONF" >"$TMP/xray.log" 2>&1 & XPID=$!
for _ in $(seq 1 40); do ss -H -ltn "sport = :$PROBE_XRAY_PORT" 2>/dev/null | grep -q . && break; sleep 0.2; done
ss -H -ltn "sport = :$PROBE_XRAY_PORT" | grep -q . || { cat "$TMP/xray.log" >&2 || true; die "temporary XUDP probe failed"; }

probe_http(){
  local label=$1 url=$2 mode=$3 code
  code=$(curl -4 -sS -L --socks5-hostname "127.0.0.1:${PROBE_XRAY_PORT}" --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' "$url" || true)
  if [[ "$mode" == 204 ]]; then [[ "$code" == 204 ]] || die "$NAME $label failed HTTP=${code:-000}";
  else [[ "$code" =~ ^[234][0-9][0-9]$ ]] || die "$NAME $label failed HTTP=${code:-000}"; fi
  log "$NAME $label = OK (HTTP=$code)"
}
probe_http gstatic https://www.gstatic.com/generate_204 204
probe_http youtube https://www.youtube.com/ any
probe_http ytimg https://i.ytimg.com/ any
probe_http instagram https://www.instagram.com/ any

read -r code size secs < <(curl -4 -sS -L --socks5-hostname "127.0.0.1:${PROBE_XRAY_PORT}" --connect-timeout 8 --max-time 25 -o /dev/null -w '%{http_code} %{size_download} %{time_total}\n' 'https://speed.cloudflare.com/__down?bytes=1000000' || echo '000 0 99')
[[ "$code" == 200 && "$size" =~ ^[0-9]+$ && "$size" -ge 750000 ]] || die "$NAME sustained transfer failed HTTP=$code bytes=$size time=$secs"
log "$NAME sustained transfer = OK (${size} bytes in ${secs}s)"

PROBE_XRAY_PORT="$PROBE_XRAY_PORT" python3 <<'PY'
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
log "SUCCESS: $NAME passed full TCP + AnyTLS + XUDP + app + transfer + UDP probes"
