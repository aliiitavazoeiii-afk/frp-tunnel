#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=dual-trust-mieru
CONFIG_DIR=/etc/$PROJECT
STATE_DIR=/var/lib/$PROJECT
BIN_DIR=/usr/local/lib/$PROJECT
BACKUP_DIR=$STATE_DIR/backups

XRAY_VERSION=v26.9.8
MIHOMO_VERSION=v1.19.31
TRUST_ENDPOINT_VERSION=v1.0.33
TRUST_CLIENT_VERSION=v1.0.49
MIERU_VERSION=v3.37.0

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"; }
require_cmd(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

arch_name(){
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

install_base_packages(){
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends ca-certificates curl unzip gzip tar openssl jq python3 iproute2 procps util-linux
  else
    die "v1 installer currently supports Debian/Ubuntu (apt)"
  fi
}

mkdirs(){
  mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$BIN_DIR" "$BACKUP_DIR"
  chmod 0700 "$CONFIG_DIR" "$STATE_DIR" "$BACKUP_DIR"
  chmod 0755 "$BIN_DIR"
}

fetch_verified(){
  local url=$1 sha=$2 out=$3
  curl -fL --retry 4 --retry-all-errors --connect-timeout 10 --max-time 240 -o "$out" "$url"
  echo "$sha  $out" | sha256sum -c - >/dev/null || die "SHA256 mismatch for $url"
}

install_xray(){
  mkdirs
  local arch url sha tmp zip bin
  arch=$(arch_name)
  case "$arch" in
    amd64)
      url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip"
      sha="f26f248f522ecba81fd85ee6eb501f1327b073866227c295c4d85cfd0c6ed985"
      ;;
    arm64)
      url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-arm64-v8a.zip"
      sha="d30c0c055bfb727976bedb55d1d55c9825a8a75006f71b9b5c7fb1182293284c"
      ;;
  esac
  bin="$BIN_DIR/xray-${XRAY_VERSION}"
  if [[ ! -x "$bin" ]]; then
    tmp=$(mktemp -d); zip=$tmp/xray.zip
    fetch_verified "$url" "$sha" "$zip"
    unzip -q "$zip" -d "$tmp/x"
    [[ -x "$tmp/x/xray" ]] || die "Xray archive missing xray binary"
    install -m 0755 "$tmp/x/xray" "$bin"
    rm -rf "$tmp"
  fi
  ln -sfn "$bin" "$BIN_DIR/xray"
  "$BIN_DIR/xray" version | head -n1
}

install_mihomo(){
  mkdirs
  local arch asset sha url tmp gz bin
  arch=$(arch_name)
  case "$arch" in
    amd64)
      asset="mihomo-linux-amd64-${MIHOMO_VERSION}.gz"
      sha="d5e74bbddbdfff49a1aef7775bf5911da59f0d7196ed509a0ac914b3653dd5f1"
      ;;
    arm64)
      asset="mihomo-linux-arm64-${MIHOMO_VERSION}.gz"
      sha="9e0f11afbf38426b8bd88fdc594678f8161c57eccb4e1b77acb12b493904f1d4"
      ;;
  esac
  url="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/${asset}"
  bin="$BIN_DIR/mihomo-${MIHOMO_VERSION}"
  if [[ ! -x "$bin" ]]; then
    tmp=$(mktemp -d); gz=$tmp/mihomo.gz
    fetch_verified "$url" "$sha" "$gz"
    gzip -dc "$gz" > "$tmp/mihomo"
    chmod 0755 "$tmp/mihomo"
    "$tmp/mihomo" -v >/dev/null || die "downloaded Mihomo cannot execute"
    install -m 0755 "$tmp/mihomo" "$bin"
    rm -rf "$tmp"
  fi
  ln -sfn "$bin" "$BIN_DIR/mihomo"
  "$BIN_DIR/mihomo" -v | head -n1
}

install_trust_endpoint(){
  mkdirs
  local arch asset sha url tmp tgz found bin
  arch=$(arch_name)
  case "$arch" in
    amd64)
      asset="trusttunnel_endpoint-x86_64-unknown-linux-gnu-${TRUST_ENDPOINT_VERSION}.tar.gz"
      sha="c6bc3c15db700278497e31e7a70c5c14c6866f10a5193a7c2dce353d7c578114"
      ;;
    arm64)
      asset="trusttunnel_endpoint-aarch64-unknown-linux-gnu-${TRUST_ENDPOINT_VERSION}.tar.gz"
      sha="a7deedf5e81d63ba744242e94aa6350b02d3e54993910d133793f92d6a2f9517"
      ;;
  esac
  url="https://github.com/TrustTunnel/TrustTunnel/releases/download/${TRUST_ENDPOINT_VERSION}/${asset}"
  bin="$BIN_DIR/trusttunnel_endpoint-${TRUST_ENDPOINT_VERSION}"
  if [[ ! -x "$bin" ]]; then
    tmp=$(mktemp -d); mkdir -p "$tmp/x"; tgz=$tmp/trust.tgz
    fetch_verified "$url" "$sha" "$tgz"
    tar -xzf "$tgz" -C "$tmp/x"
    found=$(find "$tmp/x" -type f -name trusttunnel_endpoint -perm -u+x | head -n1 || true)
    [[ -n "$found" ]] || die "TrustTunnel endpoint archive missing binary"
    install -m 0755 "$found" "$bin"
    rm -rf "$tmp"
  fi
  ln -sfn "$bin" "$BIN_DIR/trusttunnel_endpoint"
  "$BIN_DIR/trusttunnel_endpoint" --version || true
}

install_trust_client(){
  mkdirs
  local arch asset sha url tmp tgz found bin
  arch=$(arch_name)
  case "$arch" in
    amd64)
      asset="trusttunnel_client-x86_64-unknown-linux-gnu-${TRUST_CLIENT_VERSION}.tar.gz"
      sha="2c0721371de6087a7fbe6052549255914370485147971e465947d455284bc8b4"
      ;;
    arm64)
      asset="trusttunnel_client-aarch64-unknown-linux-gnu-${TRUST_CLIENT_VERSION}.tar.gz"
      sha="9d4bed106b7065d23aca61c05016f9bfb715643d2bda2d5da16356c3007a88bc"
      ;;
  esac
  url="https://github.com/TrustTunnel/TrustTunnelClient/releases/download/${TRUST_CLIENT_VERSION}/${asset}"
  bin="$BIN_DIR/trusttunnel_client-${TRUST_CLIENT_VERSION}"
  if [[ ! -x "$bin" ]]; then
    tmp=$(mktemp -d); mkdir -p "$tmp/x"; tgz=$tmp/trust.tgz
    fetch_verified "$url" "$sha" "$tgz"
    tar -xzf "$tgz" -C "$tmp/x"
    found=$(find "$tmp/x" -type f -name trusttunnel_client -perm -u+x | head -n1 || true)
    [[ -n "$found" ]] || die "TrustTunnel client archive missing binary"
    install -m 0755 "$found" "$bin"
    rm -rf "$tmp"
  fi
  ln -sfn "$bin" "$BIN_DIR/trusttunnel_client"
  "$BIN_DIR/trusttunnel_client" --version || true
}

install_mieru_deb(){
  local which=$1 arch asset sha url tmp deb
  arch=$(arch_name)
  case "$which:$arch" in
    client:amd64) asset="mieru_${MIERU_VERSION#v}_amd64.deb"; sha="261b818eff12b61ca949315d7aa5c0f2bc7d88fc95f875f8129a8c446c7f94ee" ;;
    client:arm64) asset="mieru_${MIERU_VERSION#v}_arm64.deb"; sha="f1c0ef12b9d38264b7949722cb7db19be2c33be17d98983359e6a26e5f45e8b4" ;;
    server:amd64) asset="mita_${MIERU_VERSION#v}_amd64.deb"; sha="22248dc1568280a8b1bdaf55051a59b3d64ac1edb4ec4918e3925088f78a35de" ;;
    server:arm64) asset="mita_${MIERU_VERSION#v}_arm64.deb"; sha="d82a7d3c76e8dad42c2736955c5c08ad7ad8f99cafefe2ef4cd1f497ec8d3caa" ;;
    *) die "unsupported Mieru package selection" ;;
  esac
  url="https://github.com/enfein/mieru/releases/download/${MIERU_VERSION}/${asset}"
  tmp=$(mktemp -d); deb=$tmp/$asset
  fetch_verified "$url" "$sha" "$deb"
  dpkg -i "$deb" >/dev/null || { apt-get -f install -y; dpkg -i "$deb" >/dev/null; }
  rm -rf "$tmp"
}

json_uuid(){ python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
}

free_port(){
  local p=$1
  ! ss -H -ltn "sport = :$p" 2>/dev/null | grep -q . || die "TCP/$p already in use"
}
