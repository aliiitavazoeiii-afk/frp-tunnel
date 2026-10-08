#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=/etc/maya4-naive
STATE=/var/lib/maya4-naive
BIN=/usr/local/lib/maya4-naive
NAIVE_PORT=7995
ENTRY_PORT=7996
XRAY_VERSION=v26.9.8

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
root_only(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die 'run as root'; }

arch(){
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

mkdirs(){
  mkdir -p "$ROOT" "$STATE" "$BIN" "$STATE/backups"
  chmod 0700 "$ROOT" "$STATE" "$STATE/backups"
  chmod 0755 "$BIN"
}

packages(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends \
    ca-certificates curl jq python3 openssh-client git xz-utils tar unzip \
    openssl iproute2 procps util-linux >/dev/null
}

install_xray(){
  mkdirs
  local a url sha tmp zip
  a=$(arch)
  case "$a" in
    amd64)
      url="https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-64.zip"
      sha="a8c6d5b53957600d7e18d16e697201a4c942fe823307deb039bf8f40587aa556"
      ;;
    arm64)
      url="https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-arm64-v8a.zip"
      sha="6721edb5b80e046536abc8235bd0977a2c69ade88ad42c01c0df368beba070dc"
      ;;
  esac
  if [[ ! -x "$BIN/xray-$XRAY_VERSION" ]]; then
    tmp=$(mktemp -d); zip="$tmp/xray.zip"
    curl -fL --retry 4 --retry-all-errors --connect-timeout 10 --max-time 240 -o "$zip" "$url"
    echo "$sha  $zip" | sha256sum -c - >/dev/null || die 'Xray SHA256 mismatch'
    unzip -q "$zip" -d "$tmp/x"
    install -m 0755 "$tmp/x/xray" "$BIN/xray-$XRAY_VERSION"
    rm -rf "$tmp"
  fi
  ln -sfn "$BIN/xray-$XRAY_VERSION" "$BIN/xray"
}

install_naive(){
  mkdirs
  local a suffix meta tag asset url digest tmp arc found
  a=$(arch)
  case "$a" in
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
  [[ -n "$tag" && -n "$asset" && -n "$url" && "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || die 'could not resolve verified Naive release'
  if [[ ! -x "$BIN/naive-$tag" ]]; then
    tmp=$(mktemp -d); arc="$tmp/$asset"
    curl -fL --retry 4 --retry-all-errors --connect-timeout 10 --max-time 240 -o "$arc" "$url"
    echo "${digest#sha256:}  $arc" | sha256sum -c - >/dev/null || die 'Naive SHA256 mismatch'
    mkdir -p "$tmp/x"; tar -xJf "$arc" -C "$tmp/x"
    found=$(find "$tmp/x" -type f -name naive -perm -u+x | head -n1 || true)
    [[ -n "$found" ]] || die 'Naive archive missing executable'
    install -m 0755 "$found" "$BIN/naive-$tag"
    rm -rf "$tmp"
  fi
  ln -sfn "$BIN/naive-$tag" "$BIN/naive"
}

valid_ipv4(){
  local IFS=. a b c d extra o
  read -r a b c d extra <<<"$1"
  [[ -z ${extra:-} && -n ${a:-} && -n ${b:-} && -n ${c:-} && -n ${d:-} ]] || return 1
  for o in "$a" "$b" "$c" "$d"; do
    [[ "$o" =~ ^[0-9]{1,3}$ ]] && ((10#$o <= 255)) || return 1
  done
}

http_probe(){
  local port=$1 code
  code=$(curl -4 -sS --socks5-hostname "127.0.0.1:$port" --connect-timeout 5 --max-time 12 \
    -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null || true)
  [[ "$code" == 204 ]]
}

udp_probe(){
  local port=$1
  PROBE_SOCKS_PORT="$port" python3 <<'PY' >/dev/null 2>&1
import os,random,socket,struct
h='127.0.0.1'; p=int(os.environ['PROBE_SOCKS_PORT'])
def r(s,n):
 b=b''
 while len(b)<n:
  x=s.recv(n-len(b))
  if not x: raise RuntimeError('closed')
  b+=x
 return b
s=socket.create_connection((h,p),timeout=5)
s.sendall(b'\x05\x01\x00')
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
u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); u.settimeout(6)
u.sendto(pkt,(relay,rp)); data,_=u.recvfrom(4096)
if len(data)<12: raise RuntimeError('short')
PY
}
