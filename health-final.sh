#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="anytls-tunnel"
CONFIG_DIR="/etc/${PROJECT}"
ROLE_FILE="${CONFIG_DIR}/role"
DEPLOY_ENV="${CONFIG_DIR}/deploy.env"
XUI_RUNTIME="/usr/local/x-ui/bin/config.json"
FAIL=0

ok(){ printf 'OK   %s\n' "$*"; }
warn(){ printf 'WARN %s\n' "$*"; }
bad(){ printf 'FAIL %s\n' "$*" >&2; FAIL=1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }
[[ -f "$ROLE_FILE" ]] || { echo "ERROR: missing $ROLE_FILE" >&2; exit 1; }
ROLE=$(tr -d '[:space:]' < "$ROLE_FILE")
case "$ROLE" in iran|foreign-a|foreign-b) ;; *) echo "ERROR: invalid role=$ROLE" >&2; exit 1;; esac

echo "AnyTLS FINAL health check"
echo "role=$ROLE"
echo

check_service(){
  local s=$1
  if systemctl is-active --quiet "$s"; then ok "service active: $s"; else bad "service inactive: $s"; fi
  if systemctl is-enabled --quiet "$s" 2>/dev/null; then ok "service enabled: $s"; else warn "service not enabled: $s"; fi
}

check_service anytls-tunnel
check_service anytls-xudp-bridge

if [[ "$ROLE" == foreign-* ]]; then
  if ss -H -ltn 'sport = :443' | grep -q .; then ok "AnyTLS listening on TCP/443"; else bad "TCP/443 listener missing"; fi

  mapfile -t xudp_lines < <(ss -H -ltn 'sport = :2443' || true)
  if (( ${#xudp_lines[@]} == 0 )); then
    bad "XUDP loopback listener 2443 missing"
  else
    if printf '%s\n' "${xudp_lines[@]}" | grep -Eq '(^|[[:space:]])(0\.0\.0\.0|\[::\]|\*):2443([[:space:]]|$)'; then
      bad "XUDP 2443 is publicly bound; expected loopback only"
    elif printf '%s\n' "${xudp_lines[@]}" | grep -Eq '127\.0\.0\.1:2443|\[::1\]:2443'; then
      ok "XUDP endpoint is loopback-only on 2443"
    else
      warn "could not prove 2443 loopback binding from ss output"
      printf '%s\n' "${xudp_lines[@]}"
    fi
  fi

  if [[ -x /usr/local/bin/mihomo-anytls-tunnel ]]; then
    ok "Mihomo binary present"
  else
    bad "Mihomo binary missing"
  fi

else
  check_service x-ui

  for p in 443 7890 7891 9090; do
    if ss -H -ltn "sport = :$p" | grep -q .; then ok "listener present: $p"; else bad "listener missing: $p"; fi
  done

  if [[ -x /usr/local/sbin/anytls-xudp-health ]]; then
    echo
    echo "--- built-in XUDP health ---"
    if /usr/local/sbin/anytls-xudp-health; then ok "built-in XUDP health"; else bad "built-in XUDP health failed"; fi
  else
    warn "anytls-xudp-health helper missing"
  fi

  if [[ -f "$XUI_RUNTIME" ]]; then
    echo
    echo "--- x-ui final-state validation ---"
    if python3 <<'PY'
import json,sys
p='/usr/local/x-ui/bin/config.json'
cfg=json.load(open(p))
obs=[o for o in cfg.get('outbounds',[]) if o.get('tag')=='anytls-tunnel']
if len(obs)!=1:
    raise SystemExit(f'expected exactly one anytls-tunnel outbound, found {len(obs)}')
o=obs[0]
if o.get('protocol')!='socks':
    raise SystemExit('anytls-tunnel protocol is not socks')
st=o.get('settings',{})
servers=st.get('servers') or []
if not servers:
    raise SystemExit('anytls-tunnel SOCKS server missing')
s=servers[0]
if s.get('address')!='127.0.0.1' or int(s.get('port') or 0)!=7891:
    raise SystemExit(f'wrong SOCKS target: {s.get("address")}:{s.get("port")}')
if o.get('targetStrategy')!='AsIs':
    raise SystemExit(f'targetStrategy={o.get("targetStrategy")!r}; expected AsIs')
if (o.get('mux') or {}).get('enabled') is not False:
    raise SystemExit('generic x-ui SOCKS mux must be disabled')
ins=[]
for i in cfg.get('inbounds',[]):
    try: port=int(i.get('port',0))
    except Exception: continue
    if port==443 and str(i.get('listen','')) not in ('127.0.0.1','::1','localhost'):
        ins.append(i)
if len(ins)!=1:
    raise SystemExit(f'expected exactly one public :443 inbound, found {len(ins)}')
i=ins[0]; sn=i.get('sniffing') or {}
if sn.get('enabled') is not True:
    raise SystemExit('public :443 sniffing is disabled')
need={'http','tls','quic','fakedns'}
if not need.issubset(set(sn.get('destOverride') or [])):
    raise SystemExit(f'destOverride incomplete: {sn.get("destOverride")}')
if sn.get('metadataOnly') is not False or sn.get('routeOnly') is not False:
    raise SystemExit(f'sniffing flags wrong: {sn}')
rules=cfg.get('routing',{}).get('rules',[])
tag=i.get('tag')
if not any(r.get('outboundTag')=='anytls-tunnel' and tag in (r.get('inboundTag') or []) for r in rules):
    raise SystemExit(f'route missing: {tag} -> anytls-tunnel')
print(f'RUNTIME FINAL OK: {tag} -> anytls-tunnel -> 127.0.0.1:7891, AsIs, sniffing=ON')
PY
    then ok "x-ui runtime matches final state"; else bad "x-ui runtime final-state validation failed"; fi
  else
    bad "x-ui runtime config missing: $XUI_RUNTIME"
  fi

  echo
  echo "--- XUDP UDP round-trip ---"
  if XUDP_PORT=7891 python3 <<'PY'
import os,random,socket,struct,sys,time
host='127.0.0.1'; port=int(os.environ['XUDP_PORT'])
def recvn(s,n):
    b=b''
    while len(b)<n:
        x=s.recv(n-len(b))
        if not x: raise RuntimeError('SOCKS TCP closed')
        b+=x
    return b
s=socket.create_connection((host,port),timeout=5)
s.sendall(b'\x05\x01\x00')
if recvn(s,2)!=b'\x05\x00': raise RuntimeError('SOCKS auth failed')
s.sendall(b'\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00')
_,rep,_,atyp=recvn(s,4)
if rep: raise RuntimeError(f'UDP ASSOCIATE reply={rep}')
if atyp==1: relay=socket.inet_ntoa(recvn(s,4))
elif atyp==3: relay=recvn(s,recvn(s,1)[0]).decode()
elif atyp==4: relay=socket.inet_ntop(socket.AF_INET6,recvn(s,16))
else: raise RuntimeError('bad relay ATYP')
rport=struct.unpack('!H',recvn(s,2))[0]
if relay in ('0.0.0.0','::'): relay=host
qid=random.randrange(65536)
qname=b''.join(bytes([len(x)])+x.encode() for x in 'youtube.com'.split('.'))+b'\0'
dns=struct.pack('!HHHHHH',qid,0x0100,1,0,0,0)+qname+struct.pack('!HH',1,1)
pkt=b'\0\0\0\1'+socket.inet_aton('1.1.1.1')+struct.pack('!H',53)+dns
u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); u.settimeout(8)
t=time.time(); u.sendto(pkt,(relay,rport)); data,_=u.recvfrom(65535)
pos=4; ratyp=data[3]
if ratyp==1: pos+=4
elif ratyp==3: pos+=1+data[pos]
elif ratyp==4: pos+=16
else: raise RuntimeError('bad reply ATYP')
pos+=2; reply=data[pos:]
if len(reply)<12: raise RuntimeError('short DNS reply')
rid,flags=struct.unpack('!HH',reply[:4])
if rid!=qid or not(flags & 0x8000): raise RuntimeError('invalid DNS reply')
print(f'UDP XUDP TEST = OK ({time.time()-t:.3f}s, rcode={flags & 0xF})')
PY
  then ok "UDP round-trip through XUDP"; else bad "UDP round-trip through XUDP failed"; fi

  echo
  echo "--- remote-resolution application probes through 7891 ---"
  probe_remote(){
    local name=$1 url=$2 expect=${3:-any} code
    code=$(curl -4 -sS -L --socks5-hostname 127.0.0.1:7891 --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' "$url" || true)
    if [[ "$expect" == "204" ]]; then
      if [[ "$code" == "204" ]]; then ok "$name remote DNS/path HTTP=$code"; else bad "$name remote DNS/path HTTP=${code:-000}"; fi
    else
      if [[ -n "$code" && "$code" != "000" ]]; then ok "$name remote DNS/path HTTP=$code"; else bad "$name remote DNS/path failed"; fi
    fi
  }
  probe_remote gstatic https://www.gstatic.com/generate_204 204
  probe_remote ytimg https://i.ytimg.com/ any
  probe_remote instagram https://www.instagram.com/ any

  if [[ -f "$DEPLOY_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$DEPLOY_ENV"
    if [[ -n "${CONTROLLER_SECRET:-}" && -n "${LOCAL_CONTROLLER_PORT:-}" ]]; then
      echo
      echo "--- per-node controller probes ---"
      API="http://127.0.0.1:${LOCAL_CONTROLLER_PORT}"
      for P in foreign-a-shadowtls foreign-b-restls; do
        out=$(curl -sS -G -H "Authorization: Bearer $CONTROLLER_SECRET" \
          --data-urlencode 'url=https://www.gstatic.com/generate_204' \
          --data-urlencode 'timeout=8000' "$API/proxies/$P/delay" || true)
        if jq -e '.delay|numbers' >/dev/null 2>&1 <<<"$out"; then
          ok "$P gstatic delay=$(jq -r '.delay' <<<"$out")ms"
        else
          bad "$P controller probe failed: ${out:-no-response}"
        fi
      done
    else
      warn "controller secret/port missing from deploy.env"
    fi
  else
    warn "deploy.env missing; skipped per-node controller probes"
  fi
fi

echo
if (( FAIL == 0 )); then
  echo "FINAL HEALTH = OK"
  exit 0
else
  echo "FINAL HEALTH = FAIL"
  exit 1
fi
