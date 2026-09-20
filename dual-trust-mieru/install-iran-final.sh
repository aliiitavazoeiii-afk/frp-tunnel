#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BASE="$B/install-iran.sh"
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }
[[ -s "$BASE" ]] || { echo "ERROR: base installer missing: $BASE" >&2; exit 1; }

TMP=$(mktemp "$B/.install-iran-final.XXXXXX.sh")
cleanup(){ rm -f "$TMP"; }
trap cleanup EXIT

python3 - "$BASE" "$TMP" <<'PY'
import sys
src,dst=sys.argv[1],sys.argv[2]
s=open(src).read()

old_mux='    multiplexing: MULTIPLEXING_LOW'
new_mux='    multiplexing: MULTIPLEXING_OFF'
if s.count(old_mux) != 1:
    raise SystemExit("ERROR: expected exactly one legacy Mieru multiplexing line")
s=s.replace(old_mux,new_mux,1)

old_routing='''  "routing":{"domainStrategy":"AsIs","rules":[
    {"type":"field","inboundTag":["trust-in"],"outboundTag":"xudp-trust"},
    {"type":"field","inboundTag":["mieru-in"],"outboundTag":"xudp-mieru"}
  ]}
'''
new_routing='''  "routing":{"domainStrategy":"AsIs","rules":[
    {"type":"field","inboundTag":["trust-in"],"network":"tcp","outboundTag":"carrier-trust"},
    {"type":"field","inboundTag":["trust-in"],"network":"udp","outboundTag":"xudp-trust"},
    {"type":"field","inboundTag":["mieru-in"],"network":"tcp","outboundTag":"carrier-mieru"},
    {"type":"field","inboundTag":["mieru-in"],"network":"udp","outboundTag":"xudp-mieru"}
  ]}
'''
if old_routing not in s:
    raise SystemExit("ERROR: legacy XUDP routing block not found")
s=s.replace(old_routing,new_routing,1)

old_trust_addr='{"tag":"xudp-trust","protocol":"vless","settings":{"address":"127.0.0.1","port":2443'
new_trust_addr='{"tag":"xudp-trust","protocol":"vless","settings":{"address":"xudp-trust.internal","port":2443'
if old_trust_addr not in s:
    raise SystemExit("ERROR: legacy Trust XUDP loopback target not found")
s=s.replace(old_trust_addr,new_trust_addr,1)

s=s.replace(
    '[[ "$sync" == true ]] || log "WARNING: NTP synchronization is not reported active; verify the Iran and Mieru-foreign clocks are close"',
    '[[ "$sync" == true || "$sync" == yes ]] || log "WARNING: NTP synchronization is not reported active; verify the Iran and Mieru-foreign clocks are close"',
    1,
)

s=s.replace(
    'Description=Dual Trust/Mieru XUDP bridge',
    'Description=Dual Trust/Mieru split router (TCP direct, UDP XUDP)',
    1,
)

open(dst,'w').write(s)
PY
chmod 0700 "$TMP"

bash -n "$TMP"

grep -qE '^[[:space:]]*127\.0\.0\.1[[:space:]]+xudp-trust\.internal([[:space:]]|$)' /etc/hosts || \
  echo '127.0.0.1 xudp-trust.internal # dual-trust-mieru trust-xudp-hostname' >> /etc/hosts

echo "=== FINAL INSTALL: TCP direct / UDP XUDP, Mieru mux OFF ==="
bash "$TMP" "$@"

install -m 0755 "$B/dual-probe-final.sh" /usr/local/sbin/dual-tunnel-probe
install -m 0755 "$B/replace-foreign-final.sh" /usr/local/sbin/dual-tunnel-replace-foreign

D=/etc/dual-trust-mieru/iran

grep -q 'multiplexing: MULTIPLEXING_OFF' "$D/mieru-carrier.yaml" ||
  { echo "ERROR: final Mieru mux mode missing" >&2; exit 1; }
! grep -q 'MULTIPLEXING_LOW' "$D/mieru-carrier.yaml" ||
  { echo "ERROR: legacy Mieru mux mode survived" >&2; exit 1; }

jq -e '
  ([.routing.rules[] | select(.inboundTag==["trust-in"] and .network=="tcp" and .outboundTag=="carrier-trust")] | length)==1 and
  ([.routing.rules[] | select(.inboundTag==["trust-in"] and .network=="udp" and .outboundTag=="xudp-trust")] | length)==1 and
  ([.routing.rules[] | select(.inboundTag==["mieru-in"] and .network=="tcp" and .outboundTag=="carrier-mieru")] | length)==1 and
  ([.routing.rules[] | select(.inboundTag==["mieru-in"] and .network=="udp" and .outboundTag=="xudp-mieru")] | length)==1
' "$D/xudp.json" >/dev/null || {
  echo "ERROR: final split routing validation failed" >&2
  exit 1
}

strict_http(){
  local label=$1 port=$2 count=$3 ok=0 code
  echo
  echo "=== $label :$port / $count strict HTTP tests ==="
  for i in $(seq 1 "$count"); do
    code=$(curl -4 -sS --socks5-hostname "127.0.0.1:$port" \
      --connect-timeout 5 --max-time 8 -o /dev/null -w '%{http_code}' \
      https://www.gstatic.com/generate_204 2>/dev/null || true)
    if [[ "$code" == 204 ]]; then
      ok=$((ok+1)); printf '%02d PASS\n' "$i"
    else
      printf '%02d FAIL HTTP=%s\n' "$i" "${code:-000}"
    fi
    sleep 0.10
  done
  echo "$label=$ok/$count"
  (( ok == count ))
}

udp_probe(){
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

strict_udp(){
  local label=$1 port=$2 count=$3 ok=0
  echo
  echo "=== $label :$port / $count strict UDP tests ==="
  for i in $(seq 1 "$count"); do
    if udp_probe "$port" >/dev/null 2>&1; then
      ok=$((ok+1)); echo "$i PASS"
    else
      echo "$i FAIL"
    fi
    sleep 0.10
  done
  echo "$label=$ok/$count"
  (( ok == count ))
}

validation_failed=0
strict_http "TRUST-DIRECT" 7993 10 || validation_failed=1
strict_http "MIERU-DIRECT" 7994 10 || validation_failed=1
strict_http "TRUST-SPLIT-TCP" 7991 20 || validation_failed=1
strict_http "MIERU-SPLIT-TCP" 7992 20 || validation_failed=1
strict_udp "TRUST-XUDP-UDP" 7991 5 || validation_failed=1
strict_udp "MIERU-XUDP-UDP" 7992 5 || validation_failed=1
strict_http "DUAL-TCP" 7990 20 || validation_failed=1

if (( validation_failed )); then
  echo "ERROR: strict final validation failed; x-ui was not touched." >&2
  echo "The installed stack is intentionally left detached for inspection." >&2
  exit 2
fi

dual-tunnel-probe --full

echo
echo "SUCCESS: FINAL DUAL TRUST+MIERU STACK INSTALLED"
echo "TCP: direct carrier on both paths"
echo "UDP: XUDP/VLESS on both paths"
echo "Mieru: MULTIPLEXING_OFF"
echo "x-ui: untouched; run attach-xui.sh explicitly after validation"
