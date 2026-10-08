#!/usr/bin/env bash
set -Eeuo pipefail

L3_ROOT=/etc/dual-trust-mieru/lane3
L3_STATE=/var/lib/dual-trust-mieru/lane3
L3_BIN=/usr/local/lib/dual-trust-mieru
L3_NAIVE_PORT=7995
L3_ENTRY_PORT=7996
L3_PREFIX='L3-'
L3_BRANCH='triple-carrier-naive'
L3_REPO='https://github.com/aliiitavazoeiii-afk/frp-tunnel.git'
L3_DISPATCHER=/etc/dual-trust-mieru/iran/dispatcher.yaml
L3_DISPATCHER_DATA=/etc/dual-trust-mieru/iran/dispatcher-data
L3_MIHOMO=/usr/local/lib/dual-trust-mieru/mihomo

l3_log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
l3_die(){ echo "ERROR: $*" >&2; exit 1; }
l3_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || l3_die 'run as root'; }
l3_mkdirs(){ mkdir -p "$L3_ROOT" "$L3_STATE" "$L3_BIN"; chmod 0700 "$L3_ROOT" "$L3_STATE"; chmod 0755 "$L3_BIN"; }
l3_arch(){
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) l3_die "unsupported architecture: $(uname -m)" ;;
  esac
}
l3_valid_ipv4(){
  local IFS=. a b c d extra o
  read -r a b c d extra <<<"$1"
  [[ -z "${extra:-}" && -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
  for o in "$a" "$b" "$c" "$d"; do [[ "$o" =~ ^[0-9]{1,3}$ ]] && (( 10#$o <= 255 )) || return 1; done
}
l3_free_tcp(){ ! ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .; }
l3_install_packages(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends ca-certificates curl jq python3 openssh-client git xz-utils tar >/dev/null
}
l3_install_naive(){
  l3_mkdirs; l3_install_packages
  local arch suffix meta tag asset url digest tmp arc found bin
  arch=$(l3_arch)
  case "$arch" in
    amd64) suffix='linux-x64.tar.xz' ;;
    arm64) suffix='linux-arm64.tar.xz' ;;
  esac
  meta=$(mktemp)
  curl -fsSL --retry 4 --connect-timeout 10 --max-time 60 \
    https://api.github.com/repos/klzgrad/naiveproxy/releases/latest -o "$meta"
  tag=$(jq -r '.tag_name // empty' "$meta")
  asset=$(jq -r --arg s "$suffix" '.assets[] | select(.name|endswith($s)) | .name' "$meta" | head -n1)
  url=$(jq -r --arg s "$suffix" '.assets[] | select(.name|endswith($s)) | .browser_download_url' "$meta" | head -n1)
  digest=$(jq -r --arg s "$suffix" '.assets[] | select(.name|endswith($s)) | (.digest // empty)' "$meta" | head -n1)
  rm -f "$meta"
  [[ -n "$tag" && -n "$asset" && -n "$url" && "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || l3_die 'could not resolve verified NaiveProxy release'
  bin="$L3_BIN/naive-$tag"
  if [[ ! -x "$bin" ]]; then
    tmp=$(mktemp -d); arc="$tmp/$asset"
    curl -fL --retry 4 --retry-all-errors --connect-timeout 10 --max-time 240 -o "$arc" "$url"
    echo "${digest#sha256:}  $arc" | sha256sum -c - >/dev/null || l3_die 'NaiveProxy SHA256 mismatch'
    mkdir -p "$tmp/x"; tar -xJf "$arc" -C "$tmp/x"
    found=$(find "$tmp/x" -type f -name naive -perm -u+x | head -n1 || true)
    [[ -n "$found" ]] || l3_die 'NaiveProxy archive missing executable'
    install -m 0755 "$found" "$bin"
    rm -rf "$tmp"
  fi
  ln -sfn "$bin" "$L3_BIN/naive"
}
l3_http(){
  local p=$1 url=${2:-https://www.gstatic.com/generate_204} expect=${3:-204} code
  code=$(curl -4 -sS --socks5-hostname "127.0.0.1:$p" --connect-timeout 5 --max-time 12 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
  [[ "$code" == "$expect" ]]
}
l3_udp(){
  local p=$1
  PROBE_SOCKS_PORT="$p" python3 <<'PY' >/dev/null 2>&1
import os,random,socket,struct
h='127.0.0.1'; p=int(os.environ['PROBE_SOCKS_PORT'])
def r(s,n):
 b=b''
 while len(b)<n:
  x=s.recv(n-len(b))
  if not x: raise RuntimeError('closed')
  b+=x
 return b
s=socket.create_connection((h,p),timeout=5); s.sendall(b'\x05\x01\x00')
if r(s,2)!=b'\x05\x00': raise RuntimeError('auth')
s.sendall(b'\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00')
_,rep,_,at=r(s,4)
if rep: raise RuntimeError(rep)
if at==1: relay=socket.inet_ntoa(r(s,4))
elif at==3: relay=r(s,r(s,1)[0]).decode()
elif at==4: relay=socket.inet_ntop(socket.AF_INET6,r(s,16))
else: raise RuntimeError('atyp')
rp=struct.unpack('!H',r(s,2))[0]
if relay in ('0.0.0.0','::'): relay=h
q=random.randrange(65536)
dns=struct.pack('!HHHHHH',q,0x100,1,0,0,0)+b'\x07youtube\x03com\x00'+struct.pack('!HH',1,1)
pkt=b'\0\0\0\1'+socket.inet_aton('1.1.1.1')+struct.pack('!H',53)+dns
u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); u.settimeout(6); u.sendto(pkt,(relay,rp)); data,_=u.recvfrom(4096)
if len(data)<12: raise RuntimeError('short')
PY
}
