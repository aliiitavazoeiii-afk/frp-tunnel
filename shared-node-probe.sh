#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="anytls-tunnel"
CONFIG_DIR="/etc/${PROJECT}"
MIHOMO="/usr/local/bin/mihomo-${PROJECT}"
XRAY="/usr/local/lib/${PROJECT}/xray-v26.3.27"
SHARED_ENV="${SHARED_ENV:-${CONFIG_DIR}/shared-node.env}"
PROBE_MIHOMO_PORT="${PROBE_MIHOMO_PORT:-17890}"
PROBE_XRAY_PORT="${PROBE_XRAY_PORT:-17891}"
XUDP_SERVER_PORT="${XUDP_SERVER_PORT:-2443}"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ -f "$SHARED_ENV" ]] || die "missing shared env: $SHARED_ENV"
[[ -x "$MIHOMO" ]] || die "missing Mihomo binary: $MIHOMO"
[[ -x "$XRAY" ]] || die "missing Xray binary: $XRAY"
[[ -f "${CONFIG_DIR}/xudp-bridge.json" ]] || die "missing XUDP bridge config"

# shellcheck disable=SC1090
source "$SHARED_ENV"
for n in SHARED_ADDR SHARED_COVER SHARED_ANYTLS_PASS SHARED_SHADOWTLS_PASS; do
  [[ -n "${!n:-}" ]] || die "missing $n in $SHARED_ENV"
done

XUDP_UUID=$(jq -r '
  .outbounds[]? | select(.tag=="xudp-inner") |
  .settings.id // empty
' "${CONFIG_DIR}/xudp-bridge.json" | head -n1)
[[ "$XUDP_UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || die "could not read valid XUDP UUID"

TMP=$(mktemp -d /tmp/anytls-shared-probe.XXXXXX)
MPID=""
XPID=""
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

log "Probe 0: TCP/443 reachability to shared F5"
if ! timeout 6 bash -c "exec 3<>/dev/tcp/${SHARED_ADDR}/443" 2>/dev/null; then
  die "shared F5 TCP/443 is not reachable"
fi

MCONF="$TMP/mihomo.yaml"
cat >"$MCONF" <<EOF
mode: rule
log-level: warning
ipv6: false

listeners:
  - name: shared-probe-socks
    type: socks
    listen: 127.0.0.1
    port: ${PROBE_MIHOMO_PORT}
    udp: true
    users: []

proxies:
  - name: foreign-shared-shadowtls
    type: anytls
    server: "${SHARED_ADDR}"
    port: 443
    password: "${SHARED_ANYTLS_PASS}"
    tls: true
    sni: "${SHARED_COVER}"
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: false
    idle-session-check-interval: 30
    idle-session-timeout: 60
    min-idle-session: 1
    shadow-tls-opts:
      version: 3
      password: "${SHARED_SHADOWTLS_PASS}"

rules:
  - MATCH,foreign-shared-shadowtls
EOF

"$MIHOMO" -t -d "$TMP" -f "$MCONF" >/dev/null
"$MIHOMO" -d "$TMP" -f "$MCONF" >"$TMP/mihomo.log" 2>&1 &
MPID=$!

for _ in $(seq 1 40); do
  ss -H -ltn "sport = :$PROBE_MIHOMO_PORT" 2>/dev/null | grep -q . && break
  sleep 0.2
done
ss -H -ltn "sport = :$PROBE_MIHOMO_PORT" | grep -q . || {
  cat "$TMP/mihomo.log" >&2 || true
  die "temporary F5 Mihomo probe failed to start"
}

XCONF="$TMP/xudp-probe.json"
cat >"$XCONF" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "shared-probe-socks",
    "listen": "127.0.0.1",
    "port": ${PROBE_XRAY_PORT},
    "protocol": "socks",
    "settings": {"auth": "noauth", "udp": true}
  }],
  "outbounds": [
    {
      "tag": "xudp-inner",
      "protocol": "vless",
      "settings": {
        "address": "127.0.0.1",
        "port": ${XUDP_SERVER_PORT},
        "id": "${XUDP_UUID}",
        "encryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "sockopt": {"dialerProxy": "shared-carrier"}
      },
      "mux": {
        "enabled": true,
        "concurrency": -1,
        "xudpConcurrency": 16,
        "xudpProxyUDP443": "allow"
      }
    },
    {
      "tag": "shared-carrier",
      "protocol": "socks",
      "settings": {
        "servers": [{"address": "127.0.0.1", "port": ${PROBE_MIHOMO_PORT}, "users": []}]
      }
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [{
      "type": "field",
      "inboundTag": ["shared-probe-socks"],
      "outboundTag": "xudp-inner"
    }]
  }
}
EOF

"$XRAY" run -test -c "$XCONF" >/dev/null
"$XRAY" run -c "$XCONF" >"$TMP/xray.log" 2>&1 &
XPID=$!

for _ in $(seq 1 40); do
  ss -H -ltn "sport = :$PROBE_XRAY_PORT" 2>/dev/null | grep -q . && break
  sleep 0.2
done
ss -H -ltn "sport = :$PROBE_XRAY_PORT" | grep -q . || {
  cat "$TMP/xray.log" >&2 || true
  die "temporary F5 XUDP probe failed to start"
}

probe_http(){
  local name=$1 url=$2 expected=$3 code
  code=$(curl -4 -sS -L --socks5-hostname "127.0.0.1:${PROBE_XRAY_PORT}" \
    --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' "$url" || true)
  if [[ "$expected" == "204" ]]; then
    [[ "$code" == "204" ]] || die "$name failed through F5/XUDP (HTTP=${code:-000})"
  else
    [[ "$code" =~ ^[234][0-9][0-9]$ ]] || die "$name failed through F5/XUDP (HTTP=${code:-000})"
  fi
  log "$name = OK (HTTP=$code)"
}

log "Probe 1: remote-DNS HTTPS through F5 + XUDP"
probe_http gstatic "https://www.gstatic.com/generate_204" 204
probe_http youtube "https://www.youtube.com/" any
probe_http ytimg "https://i.ytimg.com/" any
probe_http instagram "https://www.instagram.com/" any

log "Probe 2: sustained HTTPS transfer through F5 + XUDP"
read -r code size secs < <(
  curl -4 -sS -L --socks5-hostname "127.0.0.1:${PROBE_XRAY_PORT}" \
    --connect-timeout 8 --max-time 25 \
    -o /dev/null \
    -w '%{http_code} %{size_download} %{time_total}\n' \
    "https://speed.cloudflare.com/__down?bytes=2000000" || echo "000 0 99"
)
[[ "$code" == "200" && "$size" =~ ^[0-9]+$ && "$size" -ge 1500000 ]] \
  || die "sustained transfer failed (HTTP=$code bytes=$size time=$secs)"
log "sustained transfer = OK (${size} bytes in ${secs}s)"

log "Probe 3: UDP DNS round-trip through F5 + XUDP"
PROBE_XRAY_PORT="$PROBE_XRAY_PORT" python3 <<'PY'
import os, random, socket, struct, time
host="127.0.0.1"; port=int(os.environ["PROBE_XRAY_PORT"])
def recvn(s,n):
    b=b""
    while len(b)<n:
        x=s.recv(n-len(b))
        if not x: raise RuntimeError("SOCKS TCP closed")
        b+=x
    return b
tcp=socket.create_connection((host,port),timeout=5)
tcp.sendall(b"\x05\x01\x00")
if recvn(tcp,2)!=b"\x05\x00": raise RuntimeError("SOCKS auth failed")
tcp.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
_,rep,_,atyp=recvn(tcp,4)
if rep: raise RuntimeError(f"UDP ASSOCIATE reply={rep}")
if atyp==1: relay=socket.inet_ntoa(recvn(tcp,4))
elif atyp==3: relay=recvn(tcp,recvn(tcp,1)[0]).decode()
elif atyp==4: relay=socket.inet_ntop(socket.AF_INET6,recvn(tcp,16))
else: raise RuntimeError("bad relay ATYP")
rport=struct.unpack("!H",recvn(tcp,2))[0]
if relay in ("0.0.0.0","::"): relay=host
qid=random.randrange(65536)
qname=b"".join(bytes([len(x)])+x.encode() for x in "youtube.com".split("."))+b"\0"
dns=struct.pack("!HHHHHH",qid,0x0100,1,0,0,0)+qname+struct.pack("!HH",1,1)
pkt=b"\0\0\0\1"+socket.inet_aton("1.1.1.1")+struct.pack("!H",53)+dns
udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); udp.settimeout(8)
t=time.time(); udp.sendto(pkt,(relay,rport)); data,_=udp.recvfrom(65535)
pos=4; ratyp=data[3]
if ratyp==1: pos+=4
elif ratyp==3: pos+=1+data[pos]
elif ratyp==4: pos+=16
else: raise RuntimeError("bad reply ATYP")
pos+=2; reply=data[pos:]
if len(reply)<12: raise RuntimeError("short DNS reply")
rid,flags=struct.unpack("!HH",reply[:4])
if rid!=qid or not(flags & 0x8000): raise RuntimeError("invalid DNS reply")
print(f"UDP XUDP PROBE = OK ({time.time()-t:.3f}s, rcode={flags & 0xF})")
PY

log "SUCCESS: shared F5 passed TCP + HTTPS/CDN + sustained-transfer + UDP/XUDP probes"
