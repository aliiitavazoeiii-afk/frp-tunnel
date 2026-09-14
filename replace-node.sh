#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="anytls-tunnel"
REPO_DIR="${ANYTLS_REPO_DIR:-/opt/anytls-tunnel}"
CONFIG_DIR="/etc/${PROJECT}"
STATE_DIR="/var/lib/${PROJECT}"
ROOT_ENV="/root/anytls-iran.env"
DEPLOY_ENV="${CONFIG_DIR}/deploy.env"
MIHOMO="/usr/local/bin/mihomo-${PROJECT}"
XRAY="/usr/local/lib/${PROJECT}/xray-v26.3.27"
SERVICE="${PROJECT}"
XUDP_SERVICE="anytls-xudp-bridge"
XUDP_UUID="${XUDP_UUID:-503f2cf6-608f-4f76-9f7e-17721dde09cf}"
XUDP_SERVER_PORT="${XUDP_SERVER_PORT:-2443}"
PROBE_MIHOMO_PORT="${PROBE_MIHOMO_PORT:-17890}"
PROBE_XRAY_PORT="${PROBE_XRAY_PORT:-17891}"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ -f "$CONFIG_DIR/role" ]] || die "AnyTLS role file missing"
ROLE=$(tr -d '[:space:]' < "$CONFIG_DIR/role")
[[ "$ROLE" == "iran" ]] || die "anytls-replace must run on the Iran server"
[[ -f "$DEPLOY_ENV" ]] || die "missing $DEPLOY_ENV"
[[ -x "$MIHOMO" ]] || die "Mihomo binary missing: $MIHOMO"
[[ -x "$XRAY" ]] || die "Xray XUDP binary missing: $XRAY"
[[ -f "$REPO_DIR/install.sh" ]] || die "repo/install.sh missing at $REPO_DIR"
systemctl is-active --quiet "$SERVICE" || die "$SERVICE is not active"
systemctl is-active --quiet "$XUDP_SERVICE" || die "$XUDP_SERVICE is not active"

# shellcheck disable=SC1090
source "$DEPLOY_ENV"

for n in NODE_A_ADDR NODE_B_ADDR COVER_HOST_A COVER_HOST_B ANYTLS_PASS_A SHADOWTLS_PASS_A ANYTLS_PASS_B RESTLS_PASS_B CONTROLLER_SECRET LOCAL_SOCKS_PORT LOCAL_CONTROLLER_PORT QUIC_SAFE_MODE; do
  [[ -n "${!n:-}" ]] || die "missing $n in $DEPLOY_ENV"
done

valid_addr(){ [[ "$1" =~ ^[A-Za-z0-9._:-]+$ ]]; }
valid_host(){ [[ "$1" =~ ^[A-Za-z0-9.-]+$ && "$1" == *.* && "$1" != *:* ]]; }
valid_secret(){ [[ ${#1} -ge 24 ]]; }
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )); }

prompt_default(){
  local __var=$1 label=$2 def=$3 val
  read -r -p "$label [$def]: " val
  printf -v "$__var" '%s' "${val:-$def}"
}
prompt_secret(){
  local __var=$1 label=$2 val
  while :; do
    read -r -s -p "$label: " val; echo
    valid_secret "$val" && break
    echo "Secret must be at least 24 characters."
  done
  printf -v "$__var" '%s' "$val"
}
write_env_file(){
  local path=$1
  umask 077
  cat > "$path" <<EOF
NODE_A_ADDR=$(printf %q "$NODE_A_ADDR")
NODE_B_ADDR=$(printf %q "$NODE_B_ADDR")
COVER_HOST_A=$(printf %q "$COVER_HOST_A")
COVER_HOST_B=$(printf %q "$COVER_HOST_B")
ANYTLS_PASS_A=$(printf %q "$ANYTLS_PASS_A")
SHADOWTLS_PASS_A=$(printf %q "$SHADOWTLS_PASS_A")
ANYTLS_PASS_B=$(printf %q "$ANYTLS_PASS_B")
RESTLS_PASS_B=$(printf %q "$RESTLS_PASS_B")
QUIC_SAFE_MODE=$(printf %q "$QUIC_SAFE_MODE")
CONTROLLER_SECRET=$(printf %q "$CONTROLLER_SECRET")
LOCAL_SOCKS_PORT=$(printf %q "$LOCAL_SOCKS_PORT")
LOCAL_CONTROLLER_PORT=$(printf %q "$LOCAL_CONTROLLER_PORT")
EOF
  chmod 600 "$path"
}

echo "============================================================"
echo "AnyTLS safe node replacement"
echo "  1) F1 = Foreign A / ShadowTLS v3"
echo "  2) F2 = Foreign B / ResTLS"
echo "============================================================"
read -r -p "Replace which node? [1/2]: " pick
case "$pick" in
  1|f1|F1)
    NODE="f1"; OLD_ADDR="$NODE_A_ADDR"; OLD_COVER="$COVER_HOST_A"
    prompt_default NEW_ADDR "New Foreign A public IP/hostname" "$OLD_ADDR"
    prompt_default NEW_COVER "New Foreign A cover hostname" "$OLD_COVER"
    prompt_secret NEW_ANYTLS "New ANYTLS_PASS_A"
    prompt_secret NEW_LAYER "New SHADOWTLS_PASS_A"
    valid_addr "$NEW_ADDR" || die "invalid new address"
    valid_host "$NEW_COVER" || die "invalid cover hostname"
    ;;
  2|f2|F2)
    NODE="f2"; OLD_ADDR="$NODE_B_ADDR"; OLD_COVER="$COVER_HOST_B"
    prompt_default NEW_ADDR "New Foreign B public IP/hostname" "$OLD_ADDR"
    prompt_default NEW_COVER "New Foreign B cover hostname" "$OLD_COVER"
    prompt_secret NEW_ANYTLS "New ANYTLS_PASS_B"
    prompt_secret NEW_LAYER "New RESTLS_PASS_B"
    valid_addr "$NEW_ADDR" || die "invalid new address"
    valid_host "$NEW_COVER" || die "invalid cover hostname"
    ;;
  *) die "choose 1 or 2" ;;
esac

echo
echo "Candidate:"
echo "  node  = $NODE"
echo "  addr  = $NEW_ADDR:443"
echo "  cover = $NEW_COVER"
read -r -p "Probe this new node and replace only if all tests pass? [y/N]: " yes
[[ "${yes,,}" == "y" || "${yes,,}" == "yes" ]] || die "cancelled"

TMP=$(mktemp -d /tmp/anytls-replace.XXXXXX)
MPID=""
XPID=""
cleanup(){
  set +e
  [[ -n "$XPID" ]] && kill "$XPID" 2>/dev/null
  [[ -n "$MPID" ]] && kill "$MPID" 2>/dev/null
  wait "$XPID" 2>/dev/null
  wait "$MPID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

for p in "$PROBE_MIHOMO_PORT" "$PROBE_XRAY_PORT"; do
  valid_port "$p" || die "invalid probe port $p"
  if ss -H -ltn "sport = :$p" 2>/dev/null | grep -q .; then
    ss -ltnp "sport = :$p" || true
    die "probe port $p already in use"
  fi
done

MCONF="$TMP/mihomo.yaml"
if [[ "$NODE" == "f1" ]]; then
cat > "$MCONF" <<EOF
mode: rule
log-level: warning
ipv6: false
listeners:
  - name: replace-probe-socks
    type: socks
    listen: 127.0.0.1
    port: ${PROBE_MIHOMO_PORT}
    udp: true
    users: []
proxies:
  - name: candidate
    type: anytls
    server: "${NEW_ADDR}"
    port: 443
    password: "${NEW_ANYTLS}"
    tls: true
    sni: "${NEW_COVER}"
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: false
    idle-session-check-interval: 30
    idle-session-timeout: 60
    min-idle-session: 1
    shadow-tls-opts:
      version: 3
      password: "${NEW_LAYER}"
rules:
  - MATCH,candidate
EOF
else
cat > "$MCONF" <<EOF
mode: rule
log-level: warning
ipv6: false
listeners:
  - name: replace-probe-socks
    type: socks
    listen: 127.0.0.1
    port: ${PROBE_MIHOMO_PORT}
    udp: true
    users: []
proxies:
  - name: candidate
    type: anytls
    server: "${NEW_ADDR}"
    port: 443
    password: "${NEW_ANYTLS}"
    tls: true
    sni: "${NEW_COVER}"
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: false
    idle-session-check-interval: 30
    idle-session-timeout: 60
    min-idle-session: 1
    restls-opts:
      password: "${NEW_LAYER}"
      version-hint: tls13
rules:
  - MATCH,candidate
EOF
fi

log "Validating candidate Mihomo config"
"$MIHOMO" -t -d "$TMP" -f "$MCONF"
"$MIHOMO" -d "$TMP" -f "$MCONF" >"$TMP/mihomo.log" 2>&1 &
MPID=$!

for _ in $(seq 1 30); do
  ss -H -ltn "sport = :$PROBE_MIHOMO_PORT" 2>/dev/null | grep -q . && break
  sleep 0.2
done
ss -H -ltn "sport = :$PROBE_MIHOMO_PORT" | grep -q . || {
  cat "$TMP/mihomo.log" >&2 || true
  die "candidate Mihomo probe did not start"
}

XCONF="$TMP/xudp-probe.json"
cat > "$XCONF" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "probe-socks",
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
        "sockopt": {"dialerProxy": "candidate-carrier"}
      },
      "mux": {
        "enabled": true,
        "concurrency": -1,
        "xudpConcurrency": 16,
        "xudpProxyUDP443": "allow"
      }
    },
    {
      "tag": "candidate-carrier",
      "protocol": "socks",
      "settings": {
        "servers": [{"address": "127.0.0.1", "port": ${PROBE_MIHOMO_PORT}, "users": []}]
      }
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [{"type": "field", "inboundTag": ["probe-socks"], "outboundTag": "xudp-inner"}]
  }
}
EOF

log "Validating candidate XUDP path"
"$XRAY" run -test -c "$XCONF"
"$XRAY" run -c "$XCONF" >"$TMP/xray.log" 2>&1 &
XPID=$!
for _ in $(seq 1 30); do
  ss -H -ltn "sport = :$PROBE_XRAY_PORT" 2>/dev/null | grep -q . && break
  sleep 0.2
done
ss -H -ltn "sport = :$PROBE_XRAY_PORT" | grep -q . || {
  cat "$TMP/xray.log" >&2 || true
  die "candidate XUDP probe did not start"
}

log "Probe 1/2: HTTP 204 through candidate AnyTLS + XUDP"
code=$(curl -sS --socks5-hostname "127.0.0.1:${PROBE_XRAY_PORT}" \
  --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' \
  https://www.gstatic.com/generate_204 || true)
[[ "$code" == "204" ]] || {
  echo "Candidate HTTP probe failed: HTTP=${code:-none}" >&2
  cat "$TMP/mihomo.log" >&2 || true
  cat "$TMP/xray.log" >&2 || true
  die "new node was NOT activated"
}

log "Probe 2/2: UDP DNS round-trip through candidate AnyTLS + XUDP"
PROBE_XRAY_PORT="$PROBE_XRAY_PORT" python3 <<'PY'
import os, random, socket, struct, sys, time
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
ver,rep,rsv,atyp=recvn(tcp,4)
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
t=time.time(); udp.sendto(pkt,(relay,rport))
try: data,_=udp.recvfrom(65535)
except socket.timeout:
    print("UDP XUDP PROBE = FAIL (timeout)"); sys.exit(2)
pos=4; ratyp=data[3]
if ratyp==1: pos+=4
elif ratyp==3: pos+=1+data[pos]
elif ratyp==4: pos+=16
else: print("UDP XUDP PROBE = FAIL (bad ATYP)"); sys.exit(2)
pos+=2; reply=data[pos:]
if len(reply)<12: print("UDP XUDP PROBE = FAIL (short DNS)"); sys.exit(2)
rid,flags=struct.unpack("!HH",reply[:4])
if rid!=qid or not (flags & 0x8000):
    print("UDP XUDP PROBE = FAIL (invalid DNS)"); sys.exit(2)
print(f"UDP XUDP PROBE = OK ({time.time()-t:.3f}s, rcode={flags & 0xF})")
PY

log "Candidate passed HTTP + UDP/XUDP probes"

kill "$XPID" "$MPID" 2>/dev/null || true
wait "$XPID" 2>/dev/null || true
wait "$MPID" 2>/dev/null || true
XPID=""; MPID=""

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="$STATE_DIR/backups/replace-${STAMP}-${NODE}"
mkdir -p "$BACKUP"
cp -a "$CONFIG_DIR/config.yaml" "$BACKUP/config.yaml"
cp -a "$DEPLOY_ENV" "$BACKUP/deploy.env"
[[ -f "$ROOT_ENV" ]] && cp -a "$ROOT_ENV" "$BACKUP/root-env"

if [[ "$NODE" == "f1" ]]; then
  NODE_A_ADDR="$NEW_ADDR"
  COVER_HOST_A="$NEW_COVER"
  ANYTLS_PASS_A="$NEW_ANYTLS"
  SHADOWTLS_PASS_A="$NEW_LAYER"
else
  NODE_B_ADDR="$NEW_ADDR"
  COVER_HOST_B="$NEW_COVER"
  ANYTLS_PASS_B="$NEW_ANYTLS"
  RESTLS_PASS_B="$NEW_LAYER"
fi

NEW_ENV="$TMP/anytls-iran.env"
write_env_file "$NEW_ENV"

rollback(){
  log "Rolling production back to previous node config"
  cp -a "$BACKUP/config.yaml" "$CONFIG_DIR/config.yaml"
  cp -a "$BACKUP/deploy.env" "$DEPLOY_ENV"
  if [[ -f "$BACKUP/root-env" ]]; then cp -a "$BACKUP/root-env" "$ROOT_ENV"; fi
  systemctl restart "$SERVICE" || true
}
trap 'rc=$?; if [[ $rc -ne 0 && "${ACTIVATING:-0}" == "1" ]]; then rollback; fi; cleanup; exit $rc' EXIT

ACTIVATING=1
log "Activating replacement node in production"
cp -a "$NEW_ENV" "$ROOT_ENV"
chmod 600 "$ROOT_ENV"

if ! bash "$REPO_DIR/install.sh" iran "$ROOT_ENV"; then
  die "production installer rejected replacement"
fi

systemctl is-active --quiet "$SERVICE" || die "AnyTLS service inactive after replace"
systemctl is-active --quiet "$XUDP_SERVICE" || die "XUDP bridge inactive after replace"

log "Post-activation HTTP/XUDP verification"
prod_code=$(curl -sS --socks5-hostname 127.0.0.1:7891 \
  --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' \
  https://www.gstatic.com/generate_204 || true)
[[ "$prod_code" == "204" ]] || die "production XUDP HTTP verification failed"

ACTIVATING=0
trap cleanup EXIT

echo
echo "============================================================"
echo "SUCCESS: ${NODE^^} replaced safely"
echo "Old address : $OLD_ADDR"
echo "New address : $NEW_ADDR"
echo "Cover       : $NEW_COVER"
echo "Backup      : $BACKUP"
echo "x-ui/XUDP   : unchanged"
echo "============================================================"
