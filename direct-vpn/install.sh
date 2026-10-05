#!/usr/bin/env bash
set -Eeuo pipefail

PUBLIC_IP="${DIRECT_VPN_PUBLIC_IP:-193.57.9.80}"
DOMAIN="${DIRECT_VPN_DOMAIN:-}"
EMAIL="${DIRECT_VPN_EMAIL:-}"
BUNDLE_IN=""
CADDY_TAG="v2.11.2-naive"
CADDY_SHA256="19eccb7321dd877a5fb4a3dba6ef1b745185188b616c96cc6201f1a1fc0380a8"
CADDY_URL="https://github.com/klzgrad/forwardproxy/releases/download/${CADDY_TAG}/caddy-forwardproxy-naive.tar.xz"
BASE_DIR="/etc/direct-naive"
WEB_DIR="/var/www/direct-naive"
STATE_DIR="/var/lib/direct-naive"
BIN_DIR="/usr/local/lib/direct-naive"
BUNDLE_OUT="/root/direct-naive-client.json"
SERVICE="direct-naive.service"

log(){ printf '[direct-vpn] %s\n' "$*"; }
die(){ printf '[direct-vpn] ERROR: %s\n' "$*" >&2; exit 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die 'run as root'; }
valid_ipv4(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1; local IFS=. o; read -ra o <<<"$1"; for x in "${o[@]}"; do ((x>=0 && x<=255)) || return 1; done; }
valid_domain(){ [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]]; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --public-ip) PUBLIC_IP=${2:-}; shift 2 ;;
    --domain) DOMAIN=${2:-}; shift 2 ;;
    --email) EMAIL=${2:-}; shift 2 ;;
    --reuse-bundle) BUNDLE_IN=${2:-}; shift 2 ;;
    -h|--help)
      cat <<'EOF'
Usage: sudo bash install.sh --domain host.example.com [--public-ip 193.57.9.80] [--email you@example.com]
       sudo bash install.sh --domain host.example.com --reuse-bundle /root/direct-naive-client.json

The reuse bundle mode preserves username/password for server-side failover.
EOF
      exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

need_root
valid_ipv4 "$PUBLIC_IP" || die 'invalid public IPv4'
valid_domain "$DOMAIN" || die '--domain is required and must be a valid hostname'
if [[ -n "$EMAIL" && ! "$EMAIL" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]]; then
  die 'invalid email'
fi

if [[ -e "$BASE_DIR" || -e "/etc/systemd/system/$SERVICE" ]]; then
  die 'direct-naive already appears installed; uninstall first'
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates curl jq xz-utils openssl dnsutils python3 iproute2 >/dev/null

arch=$(uname -m)
case "$arch" in
  x86_64|amd64) ;;
  *) die "this first direct-vpn build is pinned for x86_64/amd64; detected $arch" ;;
esac

for p in 80 443; do
  if ss -H -ltn "sport = :$p" 2>/dev/null | grep -q .; then
    ss -lntp "sport = :$p" >&2 || true
    die "TCP/$p is already in use; refusing to stop or replace existing services"
  fi
done

mapfile -t dns_ips < <(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u)
printf '%s\n' "${dns_ips[@]:-}" | grep -Fxq "$PUBLIC_IP" || {
  printf 'Resolved IPv4 values for %s: %s\n' "$DOMAIN" "${dns_ips[*]:-(none)}" >&2
  die "DNS A record must point to $PUBLIC_IP before installation"
}

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow 80/tcp comment 'direct-naive-acme' >/dev/null || true
  ufw allow 443/tcp comment 'direct-naive-https' >/dev/null || true
fi

install -d -m 0700 "$BASE_DIR" "$BIN_DIR"
install -d -m 0755 "$WEB_DIR"
install -d -m 0750 "$STATE_DIR" "$STATE_DIR/data" "$STATE_DIR/config"

if ! id direct-naive >/dev/null 2>&1; then
  useradd --system --home "$STATE_DIR" --shell /usr/sbin/nologin direct-naive
fi
chown -R direct-naive:direct-naive "$STATE_DIR"

log "downloading pinned Caddy/Naive ${CADDY_TAG}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fL --retry 4 --retry-all-errors --connect-timeout 10 --max-time 240 "$CADDY_URL" -o "$tmp/caddy.tar.xz"
echo "$CADDY_SHA256  $tmp/caddy.tar.xz" | sha256sum -c - >/dev/null || die 'Caddy/Naive SHA256 mismatch'
mkdir -p "$tmp/unpack"
tar -xJf "$tmp/caddy.tar.xz" -C "$tmp/unpack"
caddy_bin=$(find "$tmp/unpack" -type f -name caddy -perm -u+x | head -n1 || true)
[[ -n "$caddy_bin" ]] || die 'caddy executable missing from verified archive'
install -m 0755 "$caddy_bin" "$BIN_DIR/caddy"

if [[ -n "$BUNDLE_IN" ]]; then
  [[ -s "$BUNDLE_IN" ]] || die 'reuse bundle not found'
  USER_NAME=$(jq -r '.username // empty' "$BUNDLE_IN")
  USER_PASS=$(jq -r '.password // empty' "$BUNDLE_IN")
  [[ "$USER_NAME" =~ ^[A-Za-z0-9._-]{3,64}$ ]] || die 'invalid username in reuse bundle'
  [[ "$USER_PASS" =~ ^[A-Za-z0-9._~-]{20,128}$ ]] || die 'invalid password in reuse bundle'
else
  USER_NAME="dv-$(openssl rand -hex 5)"
  USER_PASS="$(openssl rand -hex 32)"
fi

A=$(openssl rand -hex 6); B=$(openssl rand -hex 6); C=$(openssl rand -hex 6); D=$(openssl rand -hex 6)
install -d -m 0755 "$WEB_DIR/assets"
cat >"$WEB_DIR/index.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Media Library</title><meta name="description" content="A small media index and service status page.">
<link rel="icon" href="/assets/icon-${D}.svg"><link rel="stylesheet" href="/assets/app-${A}.css"></head>
<body><header><a href="/">Media Library</a><nav><a href="/catalog.html">Catalog</a><a href="/about.html">About</a></nav></header>
<main><section><p class="eyebrow">Archive</p><h1>Browse recent additions</h1><p>Independent media notes, releases and catalog updates.</p>
<img src="/assets/cover-${C}.svg" width="720" height="240" alt="Media library cover"></section></main>
<script src="/assets/app-${B}.js" defer></script></body></html>
EOF
cat >"$WEB_DIR/catalog.html" <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Catalog</title></head><body><main><h1>Catalog</h1><p>Index updates are published periodically.</p><p><a href="/">Home</a></p></main></body></html>
EOF
cat >"$WEB_DIR/about.html" <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>About</title></head><body><main><h1>About</h1><p>This host serves a small public media index.</p><p><a href="/">Home</a></p></main></body></html>
EOF
cat >"$WEB_DIR/assets/app-${A}.css" <<'EOF'
:root{font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#202124;background:#fafafa}*{box-sizing:border-box}body{margin:0}header{height:64px;display:flex;align-items:center;justify-content:space-between;max-width:960px;margin:auto;padding:0 24px}a{color:inherit;text-decoration:none}nav{display:flex;gap:22px;color:#5f6368}main{max-width:960px;margin:7vh auto;padding:24px}section{background:#fff;border:1px solid #e8eaed;border-radius:18px;padding:36px;box-shadow:0 8px 32px rgba(60,64,67,.08)}h1{font-size:clamp(2rem,5vw,4rem);line-height:1.05;margin:.2em 0}.eyebrow{letter-spacing:.14em;text-transform:uppercase;font-size:.78rem;color:#5f6368}img{width:100%;height:auto;margin-top:28px;border-radius:14px} @media(max-width:640px){nav{display:none}section{padding:24px}}
EOF
cat >"$WEB_DIR/assets/app-${B}.js" <<'EOF'
(()=>{document.documentElement.dataset.js="ready";const t=document.querySelector(".eyebrow");if(t)t.title="Updated";})();
EOF
cat >"$WEB_DIR/assets/cover-${C}.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 720 240"><defs><linearGradient id="g" x1="0" x2="1"><stop stop-color="#eceff1"/><stop offset="1" stop-color="#f8f9fa"/></linearGradient></defs><rect width="720" height="240" rx="24" fill="url(#g)"/><circle cx="150" cy="120" r="54" fill="#dadce0"/><rect x="240" y="72" width="330" height="18" rx="9" fill="#d2d5d8"/><rect x="240" y="108" width="260" height="14" rx="7" fill="#e0e2e4"/><rect x="240" y="138" width="300" height="14" rx="7" fill="#e0e2e4"/></svg>
EOF
cat >"$WEB_DIR/assets/icon-${D}.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#5f6368"/><path d="M18 21h28v22H18z" fill="#f8f9fa"/><path d="M24 27h16M24 33h16M24 39h10" stroke="#5f6368" stroke-width="3" stroke-linecap="round"/></svg>
EOF
find "$WEB_DIR" -type f -exec chmod 0644 {} +

TLS_LINE=""
[[ -n "$EMAIL" ]] && TLS_LINE="  tls $EMAIL"
cat >"$BASE_DIR/Caddyfile" <<EOF
{
  order forward_proxy before file_server
  admin off
  log {
    exclude http.log.error
  }
}
:443, $DOMAIN {
$TLS_LINE
  encode zstd gzip
  forward_proxy {
    basic_auth $USER_NAME $USER_PASS
    hide_ip
    hide_via
    probe_resistance
  }
  root * $WEB_DIR
  file_server
}
EOF
chmod 0600 "$BASE_DIR/Caddyfile"

"$BIN_DIR/caddy" validate --config "$BASE_DIR/Caddyfile" --adapter caddyfile >/dev/null

cat >"/etc/systemd/system/$SERVICE" <<EOF
[Unit]
Description=Direct VPN Naive HTTPS endpoint
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=direct-naive
Group=direct-naive
ExecStart=$BIN_DIR/caddy run --config $BASE_DIR/Caddyfile --adapter caddyfile
ExecReload=$BIN_DIR/caddy reload --config $BASE_DIR/Caddyfile --adapter caddyfile
Restart=always
RestartSec=2s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=false
Environment=HOME=$STATE_DIR
Environment=XDG_DATA_HOME=$STATE_DIR/data
Environment=XDG_CONFIG_HOME=$STATE_DIR/config
ReadWritePaths=$STATE_DIR

[Install]
WantedBy=multi-user.target
EOF

systemd-analyze verify "/etc/systemd/system/$SERVICE" >/dev/null
systemctl daemon-reload
systemctl enable --now "$SERVICE" >/dev/null

for _ in $(seq 1 75); do
  if systemctl is-active --quiet "$SERVICE" && ss -H -ltn 'sport = :443' 2>/dev/null | grep -q .; then break; fi
  sleep 1
done
systemctl is-active --quiet "$SERVICE" || { journalctl -u "$SERVICE" -n 120 --no-pager >&2 || true; die 'service failed to start'; }

for _ in $(seq 1 45); do
  if curl -fsS --connect-timeout 4 --max-time 10 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" >/dev/null 2>&1; then break; fi
  sleep 2
done
curl -fsS --connect-timeout 5 --max-time 15 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" >/dev/null || {
  journalctl -u "$SERVICE" -n 120 --no-pager >&2 || true
  die 'HTTPS front page/certificate is not ready'
}

export PUBLIC_IP DOMAIN EMAIL USER_NAME USER_PASS CADDY_TAG
python3 - "$BUNDLE_OUT" <<'PY'
import json,os,sys
from urllib.parse import quote
E=os.environ
u=E['USER_NAME']; p=E['USER_PASS']; d=E['DOMAIN']
share=f"naive+https://{quote(u,safe='')}:{quote(p,safe='')}@{d}:443#direct-vpn"
out={
  "version":1,"kind":"direct-naive","public_ip":E['PUBLIC_IP'],"domain":d,"port":443,
  "username":u,"password":p,"transport":"https","tls_verify":True,
  "proxy_url":f"https://{u}:{p}@{d}:443","share_link":share,
  "caddy_naive_release":E['CADDY_TAG']
}
if E.get('EMAIL'): out['cert_email']=E['EMAIL']
with open(sys.argv[1],'w') as f: json.dump(out,f,indent=2,sort_keys=True)
os.chmod(sys.argv[1],0o600)
PY

log 'SUCCESS: direct Naive endpoint is healthy on TCP/443'
log "IP: $PUBLIC_IP"
log "Domain: $DOMAIN"
log "Private client bundle: $BUNDLE_OUT"
log "Bundle SHA256: $(sha256sum "$BUNDLE_OUT" | awk '{print $1}')"
log 'Run: sudo bash health.sh'
